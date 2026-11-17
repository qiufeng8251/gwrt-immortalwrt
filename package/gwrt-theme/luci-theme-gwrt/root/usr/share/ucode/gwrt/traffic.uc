// All byte accounting is independent of the browser and of flash writes.
const fields = [ 'up4', 'down4', 'up6', 'down6' ];
export function empty_bytes() { return { up4: 0, down4: 0, up6: 0, down6: 0 }; }
export function day_key(now) {
	let d = localtime(now);
	return sprintf('%04d-%02d-%02d', d.year, d.mon, d.mday);
}
function midnight(now) {
	let d = localtime(now);
	d.hour = 0; d.min = 0; d.sec = 0;
	return timelocal(d);
}
function valid_number(n) { return (type(n) == 'int' || type(n) == 'double') && n >= 0; }

// Prefer the primary WAN's real/netifd device. PPPoE commonly reports a
// physical "wan" entry with zone "unknown"; never add LAN to the same traffic.
export function select_sample(snapshot, network, now, uptime, boot) {
	let data = snapshot?.ok == true ? snapshot.data : null;
	if (type(data?.interfaces) != 'array') return null;
	let wan = null;
	for (let item in (network?.interface || []))
		if (item.interface == 'wan') { wan = item; break; }
	let selected = null;
	for (let name in [ wan?.l3_device, wan?.device ]) {
		if (!name) continue;
		for (let item in data.interfaces)
			if (item.ifname == name && type(item.cumulative) == 'object') { selected = item; break; }
		if (selected) break;
	}
	if (!selected)
		for (let item in data.interfaces)
			if (item.zone == 'wan' && type(item.cumulative) == 'object') { selected = item; break; }
	if (!selected) return null;
	let c = selected.cumulative, m = selected.metrics || {}, bytes = empty_bytes(), rates = {}, available = {};
	for (let family in [ '4', '6' ]) {
		let up = c['up_v' + family + '_bytes'], down = c['down_v' + family + '_bytes'];
		available['ipv' + family] = valid_number(up) && valid_number(down);
		if (!available['ipv' + family]) continue;
		bytes['up' + family] = up; bytes['down' + family] = down;
		for (let direction in [ 'up', 'down' ]) {
			let rate = m[direction + '_v' + family + '_bps'];
			rates[direction + family] = valid_number(rate) ? rate / 8.0 : null;
			if (wan?.up == false) rates[direction + family] = 0;
		}
	}
	if (!available.ipv4 && !available.ipv6) return null;
	return { now, uptime, boot, source: 'bandix:' + selected.ifname, bytes, rates, available };
}

export function new_state() {
	return { version: 1, first: 0, coverage_start: 0, totals: empty_bytes(), days: {}, history: [], last: null, sampled: 0, ok: false, persisted_day: '', persisted_at: 0 };
}
function add_day(state, key, bytes, ratio) {
	if (!state.days[key]) state.days[key] = empty_bytes();
	for (let k in fields) state.days[key][k] += bytes[k] * ratio;
}

export function update_state(state, sample, now) {
	state.ok = sample != null;
	if (!sample) return state; // A failed probe must not erase any counters.
	let prev = state.last, delta = empty_bytes();
	let dated = now >= 1704067200; // Do not date records while the clock is unset.
	let compatible = prev && prev.source == sample.source && prev.boot == sample.boot && sample.uptime >= prev.uptime;
	if (!state.first && dated) { state.first = now; state.coverage_start = now; }
	if (!prev) {
		// Existing counter totals are valid, but their daily history is unknown.
		for (let k in fields) state.totals[k] = sample.bytes[k];
	} else if (compatible) {
		for (let k in fields) {
			let family = index(k, '4') >= 0 ? 'ipv4' : 'ipv6';
			if (!prev.available[family] || !sample.available[family]) continue;
			// A counter restart establishes a new baseline, never a negative delta.
			if (sample.bytes[k] >= prev.bytes[k]) delta[k] = sample.bytes[k] - prev.bytes[k];
		}
		for (let k in fields) state.totals[k] += delta[k];
	}
	let span = prev ? now - prev.now : 0;
	let monotonic_span = prev ? sample.uptime - prev.uptime : 0;
	let clock_ok = compatible && span > 0 && (span - monotonic_span >= -10 && span - monotonic_span <= 10) && prev.now >= 1704067200;
	if (dated) {
		let key = day_key(now);
		if (!state.days[key]) state.days[key] = empty_bytes();
		if (clock_ok && day_key(prev.now) == key) add_day(state, key, delta, 1);
		else if (clock_ok && span <= 120) {
			// Split the short sample spanning midnight between the two dates.
			let boundary = midnight(now), ratio = (now - boundary) * 1.0 / span;
			add_day(state, day_key(prev.now), delta, 1 - ratio);
			add_day(state, key, delta, ratio);
		} else if (prev) {
			// Preserve recorded history over a short service/router restart.
			// Clock jumps and unobserved dates cannot establish period coverage.
			if (span < 0 || (compatible && !clock_ok) || (span > 120 && day_key(prev.now) != key)) state.coverage_start = now;
		}
		for (let old in keys(state.days)) if (old < day_key(now - 400 * 86400)) delete state.days[old];
	}
	state.last = sample; state.sampled = now;
	push(state.history, { t: now * 1000, ipv4: sample.available.ipv4 ? { up: sample.rates.up4, down: sample.rates.down4 } : null, ipv6: sample.available.ipv6 ? { up: sample.rates.up6, down: sample.rates.down6 } : null });
	while (length(state.history) > 60) shift(state.history);
	return state;
}

export function checkpoint_due(state, now) {
	// Initial baseline, then one atomic checkpoint on each new local date.
	return state.first > 0 && now >= 1704067200 && now >= state.persisted_at && state.persisted_day != day_key(now);
}
function sum_period(state, start, end) {
	let sum = empty_bytes();
	for (let key, bytes in state.days)
		if (key >= start && key <= end) for (let k in fields) sum[k] += bytes[k];
	return sum;
}
export function public_state(state, now) {
	let dated = now >= 1704067200, key = dated ? day_key(now) : '', periods = [];
	if (dated && state.first) {
		let day = midnight(now), d = localtime(now);
		let week = day - ((d.wday + 6) % 7) * 86400;
		d.mday = 1; d.hour = 0; d.min = 0; d.sec = 0;
		let month = timelocal(d); d.mon = 1;
		let year = timelocal(d);
		for (let p in [ { key: 'today', label: '今天', start: day, age: 0 }, { key: 'week', label: '本周', start: week, age: 7 * 86400 }, { key: 'month', label: '本月', start: month, age: 30 * 86400 }, { key: 'year', label: '本年', start: year, age: 365 * 86400 } ]) {
			if (p.age && (now - state.coverage_start < p.age || state.coverage_start > p.start)) continue;
			push(periods, { key: p.key, label: p.label, bytes: sum_period(state, day_key(p.start), key) });
		}
	}
	let families = {};
	for (let family in [ '4', '6' ]) {
		let name = 'ipv' + family;
		families[name] = { available: state.last?.available[name] == true, up: state.last?.rates['up' + family], down: state.last?.rates['down' + family], total: state.totals['up' + family] + state.totals['down' + family] };
	}
	return { version: 1, ok: state.ok && now - state.sampled <= 20 && now >= state.sampled, sampled: state.sampled, first: state.first, source: state.last?.source, families, total: state.totals.up4 + state.totals.down4 + state.totals.up6 + state.totals.down6, history: state.history, periods, persisted_at: state.persisted_at };
}
