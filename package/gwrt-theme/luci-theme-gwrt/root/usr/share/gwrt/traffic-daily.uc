import * as fs from 'fs';
import { select_sample, new_state, update_state, checkpoint_due, public_state, day_key } from 'gwrt.traffic';

const runtime = '/tmp/gwrt-theme';
const memory_file = runtime + '/traffic-state.json';
const permanent_dir = '/etc/gwrt';
const permanent_file = permanent_dir + '/traffic-daily.json';
const action = ARGV[0];

function read_json(path) {
	try { return json(fs.readfile(path)); } catch (e) { return null; }
}
function load_state() {
	let state = read_json(memory_file) || read_json(permanent_file);
	return state?.version == 1 && type(state.totals) == 'object' && type(state.days) == 'object' && type(state.history) == 'array' ? state : new_state();
}
function atomic_write(path, value) {
	let tmp = path + '.new', text = sprintf('%J\n', value);
	if (fs.writefile(tmp, text) != length(text) || !fs.rename(tmp, path)) {
		fs.unlink(tmp);
		return false;
	}
	return true;
}
function checkpoint(state, now) {
	if (!state.first) return false;
	let st = fs.lstat(permanent_dir);
	if (!st) { fs.mkdir(permanent_dir, 0700); st = fs.lstat(permanent_dir); }
	if (st?.type != 'directory' || st.uid != 0) return false;
	let old_day = state.persisted_day, old_at = state.persisted_at;
	state.persisted_day = day_key(now); state.persisted_at = now;
	if (atomic_write(permanent_file, state)) return true;
	state.persisted_day = old_day; state.persisted_at = old_at;
	return false;
}
function read_command(command) {
	let pipe = fs.popen(command, 'r');
	if (!pipe) return null;
	let raw = pipe.read('all'), code = pipe.close();
	try { return code == 0 ? json(raw) : null; } catch (e) { return null; }
}
function ubus_call(object, method) {
	// Both arguments are compile-time constants, with bounded ubus waits.
	return read_command('/bin/ubus -t 3 call ' + object + ' ' + method + ' 2>/dev/null');
}
function bandix_snapshot() {
	let snapshot = ubus_call('luci.bandix_plus', 'getSnapshot');
	if (snapshot?.ok == true && type(snapshot?.data?.interfaces) == 'array') return snapshot;
	// Some rpcd installations do not register the Bandix object, even though
	// its executable and local service are present. The fixed plugin command
	// also reads Bandix's configured port; no browser input enters the command.
	return read_command('if [ -x /usr/bin/timeout ]; then /usr/bin/timeout 5 /usr/libexec/rpcd/luci.bandix_plus call getSnapshot; elif [ -x /bin/timeout ]; then /bin/timeout 5 /usr/libexec/rpcd/luci.bandix_plus call getSnapshot; else /usr/libexec/rpcd/luci.bandix_plus call getSnapshot; fi 2>/dev/null');
}
function probe() {
	let snapshot = bandix_snapshot();
	let network = ubus_call('network.interface', 'dump');
	let uptime = +split(fs.readfile('/proc/uptime') || '0', ' ')[0];
	let boot = trim(fs.readfile('/proc/sys/kernel/random/boot_id') || '');
	return select_sample(snapshot, network, time(), uptime, boot);
}

if (action == 'read') {
	// This path only reads: refreshing LuCI never samples or writes to flash.
	printf('%J\n', public_state(load_state(), time()));
	exit(0);
}
if (action != 'daemon') exit(1);

let lock = fs.open(runtime + '/traffic-daemon.lock', 'w', 0600);
if (!lock || !lock.lock('xn')) exit(1);
let state = load_state(), stopping = false;
signal('TERM', function() { stopping = true; });
signal('INT', function() { stopping = true; });
while (!stopping) {
	let sample = probe(), now = time();
	update_state(state, sample, now);
	if (checkpoint_due(state, now)) checkpoint(state, now);
	atomic_write(memory_file, state);
	if (!stopping) sleep(5000);
}
// An orderly service stop also keeps its final increment. Unexpected power
// loss is deliberately bounded by the once-daily flash checkpoint policy.
checkpoint(state, time());
atomic_write(memory_file, state);
