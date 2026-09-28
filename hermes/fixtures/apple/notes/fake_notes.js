// A stand-in for the Notes app object, with the parts Daisy's notes script uses (hermes/daisy/tools/apple.py),
// so the script's own logic runs under osascript without ever talking to Notes. The test puts
// `var STATE = {...}` in front of this and calls fakeNotes() where the script asks for Notes, then checks no
// app is asked for anywhere. Every change goes into EFFECTS, and the wrapper prints it to stderr.
//
// STATE: {folders: {<id>: {name, shared, notes: [<note id>...]}}, defaultFolder: <folder id>,
//         notes: {<id>: {name, body, text, folder, modified, shared, locked, attachments}}, failOn: <method name>}
var EFFECTS = [];

function fakeNotes() {
  function fail(number, message) {
    var error = new Error(message || "Can't get object.");
    error.errorNumber = number;
    throw error;
  }
  function trip(method) {
    if (STATE.failOn === method) { fail(STATE.failNumber || -1743, STATE.failMessage || 'Not authorized to send Apple events to Notes.'); }
  }
  function folderSpec(fid) {
    function need() { return STATE.folders[fid] || fail(-1728); }
    return {
      exists: function () { return !!STATE.folders[fid]; },
      id: function () { need(); return fid; },
      name: function () { return need().name; },
      shared: function () { return !!need().shared; },
      notes: collection(function () { return need().notes.slice(); }, fid)
    };
  }
  function noteSpec(id) {
    function need() { return STATE.notes[id] || fail(-1728); }
    var spec = {
      exists: function () { trip('exists'); return !!STATE.notes[id]; },
      id: function () { need(); return id; },
      name: function () { return need().name; },
      container: function () { return folderSpec(need().folder); },
      modificationDate: function () { return new Date(need().modified); },
      shared: function () { return !!need().shared; },
      passwordProtected: function () { trip('passwordProtected'); return !!need().locked; },
      plaintext: function () { if (need().locked) { fail(-1728); } return need().text; },
      attachments: function () { trip('attachments'); return new Array(need().attachments || 0); }
    };
    Object.defineProperty(spec, 'body', {
      get: function () { return function () { return need().body; }; },
      set: function (value) { need().body = value; EFFECTS.push({op: 'body', id: id, body: value}); }
    });
    return spec;
  }
  function collection(listIds, fid) {
    function ids() { return listIds().filter(function (id) { return !!STATE.notes[id]; }); }
    return {
      id: function () { trip('id'); return ids(); },
      name: function () { return ids().map(function (id) { return STATE.notes[id].name; }); },
      modificationDate: function () { return ids().map(function (id) { return new Date(STATE.notes[id].modified); }); },
      // Case-sensitive, and locked notes never match: one way Notes could behave.
      whose: function (test) {
        var wanted = test.plaintext._contains;
        return collection(function () {
          return ids().filter(function (id) { return !STATE.notes[id].locked && STATE.notes[id].text.indexOf(wanted) >= 0; });
        }, fid);
      },
      byId: function (id) { return noteSpec(id); },
      push: function (proxy) {
        trip('push');
        var id = 'x-coredata://00000000-0000-4000-8000-00000000AAAA/ICNote/p' + (900 + Object.keys(STATE.notes).length);
        var title = (proxy.properties.body.match(/<h1>(.*?)<\/h1>/) || ['', ''])[1]
          .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#x27;/g, "'").replace(/&amp;/g, '&');
        STATE.notes[id] = {name: title, body: proxy.properties.body, text: title, folder: fid, modified: STATE.now,
                           shared: !!STATE.folders[fid].shared, locked: false, attachments: 0};
        STATE.folders[fid].notes.push(id);
        EFFECTS.push({op: 'create', id: id, folder: fid, body: proxy.properties.body});
        proxy.made = id;
      }
    };
  }
  return {
    folders: {
      id: function () { trip('folders'); return Object.keys(STATE.folders); },
      name: function () { return Object.keys(STATE.folders).map(function (fid) { return STATE.folders[fid].name; }); },
      byId: folderSpec
    },
    notes: collection(function () { return Object.keys(STATE.notes); }, null),
    defaultAccount: function () { return {defaultFolder: function () { return folderSpec(STATE.defaultFolder); }}; },
    Note: function (properties) {
      var proxy = {properties: properties, made: null};
      proxy.id = function () { return proxy.made; };
      proxy.name = function () { return STATE.notes[proxy.made].name; };
      return proxy;
    }
  };
}
