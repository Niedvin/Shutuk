// JSON surgery for install.sh / uninstall.sh, run as
//   osascript -l JavaScript shut-json.js <op> [args...]   (osascript ships with macOS)
//   node shut-json.js <op> [args...]                      (same code, for testing off a Mac)
// Exit 1 means "not found" or "nothing to do", never a crash the caller should ignore — 2026-09-05

var CLAUDE_ENV = {
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION: 'false',
    CLAUDE_CODE_ENABLE_AWAY_SUMMARY: '0'
};
var OUTPUT_STYLE = 'Shut';

// ----------------------------------------------------------------- runtime shim

var IO = (function () {
    if (typeof ObjC !== 'undefined') {
        ObjC.import('Foundation');
        var fm = $.NSFileManager.defaultManager;
        return {
            exists: function (p) { return fm.fileExistsAtPath($(p)); },
            read: function (p) {
                if (!fm.fileExistsAtPath($(p))) { return null; }
                var s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, null);
                return s.js;
            },
            write: function (p, t) {
                $(t).writeToFileAtomicallyEncodingError($(p), true, $.NSUTF8StringEncoding, null);
            },
            remove: function (p) { fm.removeItemAtPathError($(p), null); },
            out: function (t) {
                var h = $.NSFileHandle.fileHandleWithStandardOutput;
                h.writeData($(t).dataUsingEncoding($.NSUTF8StringEncoding));
            },
            // Throwing is the fallback exit code: osascript reports 1 for an uncaught error — 2026-09-05
            exit: function (c) {
                try { $.exit(c); } catch (e) { }
                if (c) { throw new Error('shut-json exit ' + c); }
            }
        };
    }
    var fs = require('fs');
    return {
        exists: function (p) { return fs.existsSync(p); },
        read: function (p) { try { return fs.readFileSync(p, 'utf8'); } catch (e) { return null; } },
        write: function (p, t) { fs.writeFileSync(p, t, 'utf8'); },
        remove: function (p) { try { fs.unlinkSync(p); } catch (e) { } },
        out: function (t) { process.stdout.write(t); },
        exit: function (c) { process.exit(c); }
    };
})();

// ----------------------------------------------------------------- helpers

function readJson(path) {
    var text = IO.read(path);
    if (text === null || !text.trim()) { return {}; }
    try { return JSON.parse(text); } catch (e) { return {}; }
}

function writeJson(path, data) { IO.write(path, JSON.stringify(data, null, 2) + '\n'); }

// Every mutating op takes a trailing dry flag so --dry-run gets the real note and no write — 2026-09-05
function maybeWrite(dry, path, data) { if (dry !== '1') { writeJson(path, data); } }

function same(a, b) { return JSON.stringify(a) === JSON.stringify(b); }

function has(obj, key) { return Object.prototype.hasOwnProperty.call(obj, key); }

function stamp() {
    var d = new Date(), p = function (n) { return (n < 10 ? '0' : '') + n; };
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + 'T' +
           p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

// ----------------------------------------------------------------- ops

var OPS = {};

OPS['get'] = function (file, key) {
    var data = readJson(file);
    if (!has(data, key)) { return 1; }
    IO.out(typeof data[key] === 'string' ? data[key] : JSON.stringify(data[key]));
    return 0;
};

OPS['marker'] = function (out, pkg, version, form) {
    writeJson(out, { package: pkg, version: version, form: form, installed_at: stamp() });
    return 0;
};

OPS['payload'] = function (out, event, bodyFile) {
    var body = IO.read(bodyFile);
    if (body === null) { return 1; }
    writeJson(out, { hookSpecificOutput: { hookEventName: event, additionalContext: body.trim() } });
    return 0;
};

// Codex takes Claude Code's hook schema, so the payload is the same JSON on stdout — 2026-09-05
OPS['hook-add'] = function (hooksFile, pkg, launcher, prefix, dry) {
    var conf = readJson(hooksFile);
    if (!conf.hooks) { conf.hooks = {}; }
    if (!conf.hooks.SessionStart) { conf.hooks.SessionStart = []; }
    var groups = conf.hooks.SessionStart;
    var entry = { type: 'command', command: launcher, timeout: 5, statusMessage: 'Loading ' + pkg };

    for (var g = 0; g < groups.length; g++) {
        var hooks = groups[g].hooks || [];
        for (var h = 0; h < hooks.length; h++) {
            if (String(hooks[h].command || '').indexOf(prefix + pkg) === -1) { continue; }
            if (same(hooks[h], entry)) { IO.out('unchanged'); return 0; }
            hooks[h] = entry;
            groups[g].hooks = hooks;
            maybeWrite(dry, hooksFile, conf);
            IO.out('hook added');
            return 0;
        }
    }
    var target = null;
    for (var i = 0; i < groups.length; i++) {
        if (String(groups[i].matcher || '').indexOf('startup') === 0) { target = groups[i]; break; }
    }
    if (!target) {
        target = { matcher: 'startup|resume|clear|compact', hooks: [] };
        groups.push(target);
    }
    if (!target.hooks) { target.hooks = []; }
    target.hooks.push(entry);
    maybeWrite(dry, hooksFile, conf);
    IO.out('hook added');
    return 0;
};

OPS['hook-del'] = function (hooksFile, pkg, prefix, dry) {
    if (!IO.exists(hooksFile)) { return 1; }
    var conf = readJson(hooksFile);
    if (!conf.hooks) { return 1; }
    var changed = false, event;
    for (event in conf.hooks) {
        if (!has(conf.hooks, event)) { continue; }
        var groups = conf.hooks[event];
        for (var g = 0; g < groups.length; g++) {
            var keep = [];
            var hooks = groups[g].hooks || [];
            for (var h = 0; h < hooks.length; h++) {
                if (String(hooks[h].command || '').indexOf(prefix + pkg) === -1) { keep.push(hooks[h]); }
                else { changed = true; }
            }
            groups[g].hooks = keep;
        }
    }
    if (!changed) { return 1; }
    for (event in conf.hooks) {
        if (!has(conf.hooks, event)) { continue; }
        var kept = [];
        for (var k = 0; k < conf.hooks[event].length; k++) {
            if ((conf.hooks[event][k].hooks || []).length) { kept.push(conf.hooks[event][k]); }
        }
        if (kept.length) { conf.hooks[event] = kept; } else { delete conf.hooks[event]; }
    }
    maybeWrite(dry, hooksFile, conf);
    IO.out('changed');
    return 0;
};

// Codex skips a new or changed hook until trusted; /hooks inside Codex does that — 2026-09-05
OPS['hook-trusted'] = function (hooksFile, configToml, prefix) {
    var config = IO.read(configToml);
    if (config === null || !IO.exists(hooksFile)) { return 1; }
    var groups = (readJson(hooksFile).hooks || {}).SessionStart || [];
    for (var g = 0; g < groups.length; g++) {
        var hooks = groups[g].hooks || [];
        for (var h = 0; h < hooks.length; h++) {
            if (String(hooks[h].command || '').indexOf(prefix) === -1) { continue; }
            if (config.indexOf('hooks.json:session_start:' + g + ':' + h) === -1) { return 1; }
        }
    }
    return 0;
};

// `language` is dropped, not set: any value injects "Always respond in <lang>", killing bequiet's split — 2026-09-05
OPS['settings-apply'] = function (file, stateFile, mode, dry) {
    var wanted = {};
    if (mode === 'env' || mode === 'both') { wanted.env = true; }
    if (mode === 'style' || mode === 'both') { wanted.outputStyle = true; }

    var state = readJson(stateFile);
    if (!state.settings) { state.settings = {}; }
    if (!state.settings[file]) { state.settings[file] = {}; }
    var rec = state.settings[file];
    if (!has(rec, 'existed')) { rec.existed = IO.exists(file); }

    var conf = readJson(file);
    var out = {}, key;
    for (key in conf) { if (has(conf, key)) { out[key] = conf[key]; } }
    var changed = [];

    for (key in wanted) {
        if (!has(wanted, key)) { continue; }
        if (!has(rec, key)) { rec[key] = has(conf, key) ? conf[key] : null; }
        var before = has(conf, key) ? conf[key] : null;
        var after;
        if (key === 'env') {
            after = {};
            if (before && typeof before === 'object') {
                for (var k in before) { if (has(before, k)) { after[k] = before[k]; } }
            }
            for (var e in CLAUDE_ENV) { if (has(CLAUDE_ENV, e)) { after[e] = CLAUDE_ENV[e]; } }
        } else {
            after = OUTPUT_STYLE;
        }
        if (!same(after, before)) { changed.push(key); out[key] = after; }
    }
    if (has(conf, 'language')) {
        if (!has(rec, 'language')) { rec.language = conf.language; }
        delete out.language;
        changed.push('language dropped');
    }

    maybeWrite(dry, stateFile, state);
    if (!changed.length) { return 1; }
    maybeWrite(dry, file, out);
    IO.out(changed.join(', '));
    return 0;
};

OPS['settings-list'] = function (stateFile) {
    var settings = readJson(stateFile).settings || {};
    var paths = [], p;
    for (p in settings) { if (has(settings, p)) { paths.push(p); } }
    if (!paths.length) { return 1; }
    paths.sort();
    IO.out(paths.join('\n') + '\n');
    return 0;
};

OPS['settings-restore'] = function (file, stateFile, dry) {
    var rec = (readJson(stateFile).settings || {})[file];
    if (!rec) { return 1; }
    if (has(rec, 'existed') && !rec.existed) {
        if (!IO.exists(file)) { return 1; }
        IO.out('remove');
        return 0;
    }
    var conf = readJson(file);
    var out = {}, key;
    for (key in conf) { if (has(conf, key)) { out[key] = conf[key]; } }
    for (key in rec) {
        if (!has(rec, key) || key === 'existed') { continue; }
        if (rec[key] === null) { delete out[key]; } else { out[key] = rec[key]; }
    }
    if (same(out, conf)) { return 1; }
    maybeWrite(dry, file, out);
    IO.out('restored');
    return 0;
};

OPS['state-set'] = function (stateFile, field, json) {
    var state = readJson(stateFile);
    state[field] = JSON.parse(json);
    writeJson(stateFile, state);
    return 0;
};

OPS['state-push'] = function (stateFile, field, json) {
    var state = readJson(stateFile);
    if (!state[field]) { state[field] = []; }
    state[field].push(JSON.parse(json));
    writeJson(stateFile, state);
    return 0;
};

OPS['state-set-file'] = function (stateFile, field, file) {
    var text = IO.read(file);
    if (text === null) { return 1; }
    var state = readJson(stateFile);
    state[field] = text;
    writeJson(stateFile, state);
    return 0;
};

OPS['state-get'] = function (stateFile, field) {
    var state = readJson(stateFile);
    if (!has(state, field) || state[field] === null) { return 1; }
    IO.out(typeof state[field] === 'string' ? state[field] : JSON.stringify(state[field]));
    return 0;
};

// Tab-separated so the shell reads pairs back without a JSON parser — 2026-09-05
OPS['state-pairs'] = function (stateFile, field) {
    var list = readJson(stateFile)[field] || [];
    if (!list.length) { return 1; }
    var lines = [];
    for (var i = 0; i < list.length; i++) { lines.push(list[i][0] + '\t' + list[i][1]); }
    IO.out(lines.join('\n') + '\n');
    return 0;
};

OPS['caveman-lift'] = function (hooksFile, stateFile, dry) {
    if (!IO.exists(hooksFile)) { return 1; }
    var conf = readJson(hooksFile);
    if (!conf.hooks) { return 1; }
    var state = readJson(stateFile);
    if (!state.hooks) { state.hooks = []; }
    var changed = false, event;
    for (event in conf.hooks) {
        if (!has(conf.hooks, event)) { continue; }
        var groups = conf.hooks[event];
        for (var g = 0; g < groups.length; g++) {
            var keep = [];
            var hooks = groups[g].hooks || [];
            for (var h = 0; h < hooks.length; h++) {
                if (String(hooks[h].command || '').toLowerCase().indexOf('caveman') !== -1) {
                    state.hooks.push([event, hooks[h]]);
                    changed = true;
                } else { keep.push(hooks[h]); }
            }
            groups[g].hooks = keep;
        }
    }
    if (!changed) { return 1; }
    maybeWrite(dry, stateFile, state);
    maybeWrite(dry, hooksFile, conf);
    IO.out(String(state.hooks.length));
    return 0;
};

OPS['caveman-restore'] = function (hooksFile, stateFile, dry) {
    var entries = readJson(stateFile).hooks || [];
    if (!entries.length || !IO.exists(hooksFile)) { return 1; }
    var conf = readJson(hooksFile);
    if (!conf.hooks) { conf.hooks = {}; }
    for (var i = 0; i < entries.length; i++) {
        var event = entries[i][0], hook = entries[i][1];
        if (!conf.hooks[event]) { conf.hooks[event] = []; }
        var groups = conf.hooks[event], already = false;
        for (var g = 0; g < groups.length; g++) {
            var hooks = groups[g].hooks || [];
            for (var h = 0; h < hooks.length; h++) { if (same(hooks[h], hook)) { already = true; } }
        }
        if (already) { continue; }
        if (!groups.length) { groups.push({ matcher: 'startup|resume|clear|compact', hooks: [] }); }
        if (!groups[0].hooks) { groups[0].hooks = []; }
        groups[0].hooks.unshift(hook);
    }
    maybeWrite(dry, hooksFile, conf);
    IO.out(String(entries.length));
    return 0;
};

// ----------------------------------------------------------------- entry

function main(argv) {
    var op = argv[0];
    if (!op || !has(OPS, op)) {
        IO.out('shut-json: unknown op ' + (op || '(none)') + '\n');
        return 2;
    }
    return OPS[op].apply(null, argv.slice(1)) || 0;
}

function run(argv) { IO.exit(main(argv)); }

if (typeof ObjC === 'undefined') { IO.exit(main(process.argv.slice(2))); }
