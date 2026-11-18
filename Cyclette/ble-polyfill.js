/*
  Cyclette — Bluetooth per l'app iPhone
  ------------------------------------------------------------------
  La web app usa le API "Web Bluetooth" (navigator.bluetooth), che Safari non ha.
  Questo script viene inserito dall'app nativa PRIMA della pagina e ricrea le parti
  di Web Bluetooth usate dalla Cyclette, passando ogni richiesta a CoreBluetooth
  (file BLEBridge.swift) tramite window.webkit.messageHandlers.ble.

  Supportato: requestDevice (filters / acceptAllDevices / optionalServices),
  gatt.connect/disconnect, getPrimaryService, getCharacteristic, startNotifications,
  stopNotifications, readValue, writeValue(WithResponse/WithoutResponse),
  eventi "characteristicvaluechanged" e "gattserverdisconnected".
*/
(function () {
  'use strict';
  if (window.__bleNative) return;
  var mh = window.webkit && window.webkit.messageHandlers;
  if (!mh || !mh.ble) return;                            // non siamo dentro l'app: non fare nulla
  window.__cycletteNative = true;

  /* ---------------- UUID come li scrive Web Bluetooth (forma lunga, minuscola) ---------------- */
  var BASE = '-0000-1000-8000-00805f9b34fb';
  var NAMES = {
    fitness_machine: 0x1826, cycling_speed_and_cadence: 0x1816, heart_rate: 0x180d, battery_service: 0x180f,
    device_information: 0x180a, indoor_bike_data: 0x2ad2, fitness_machine_control_point: 0x2ad9,
    csc_measurement: 0x2a5b, heart_rate_measurement: 0x2a37, battery_level: 0x2a19,
  };
  function canon(u) {
    if (typeof u === 'number') return u.toString(16).padStart(8, '0') + BASE;
    var s = String(u).toLowerCase();
    if (Object.prototype.hasOwnProperty.call(NAMES, s)) return canon(NAMES[s]);
    if (/^(0x)?[0-9a-f]{1,8}$/.test(s)) return canon(parseInt(s, 16));
    return s;
  }

  function domErr(name, msg) {
    try { return new DOMException(msg, name); } catch (e) { var er = new Error(msg); er.name = name; return er; }
  }

  /* ---------------- Chiamate verso l'app (ognuna è una Promise con un numero) ---------------- */
  var seq = 0;
  var pending = new Map();
  function call(cmd, args) {
    return new Promise(function (resolve, reject) {
      var id = ++seq;
      pending.set(id, { resolve: resolve, reject: reject });
      mh.ble.postMessage(Object.assign({ cmd: cmd, id: id }, args || {}));
    });
  }

  function toB64(data) {
    var bytes;
    if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
    else if (ArrayBuffer.isView(data)) bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    else bytes = new Uint8Array(data);
    var bin = '';
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return btoa(bin);
  }
  function toView(b64) {
    var bin = atob(b64 || '');
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new DataView(bytes.buffer);
  }

  var devices = new Map();   // id → BluetoothDevice
  var chars = new Map();     // "dispositivo|servizio|caratteristica" → caratteristica

  /* ---------------- Oggetti come in Web Bluetooth ---------------- */
  class BluetoothDevice extends EventTarget {
    constructor(id, name) {
      super();
      this.id = id;
      this.name = name || '';
      this.gatt = new BluetoothRemoteGATTServer(this);
    }
  }

  class BluetoothRemoteGATTServer {
    constructor(device) { this.device = device; this.connected = false; }
    async connect() {
      await call('connect', { device: this.device.id });
      this.connected = true;
      return this;
    }
    disconnect() {
      if (!this.connected) return;
      this.connected = false;                              // come in Web Bluetooth: subito falso, l'evento arriva dopo
      mh.ble.postMessage({ cmd: 'disconnect', device: this.device.id });
    }
    async getPrimaryService(uuid) {
      if (!this.connected) throw domErr('NetworkError', 'Dispositivo non connesso');
      var svc = canon(uuid);
      await call('getService', { device: this.device.id, service: svc });
      return new BluetoothRemoteGATTService(this.device, svc);
    }
  }

  class BluetoothRemoteGATTService {
    constructor(device, uuid) { this.device = device; this.uuid = uuid; this.isPrimary = true; }
    async getCharacteristic(uuid) {
      var chr = canon(uuid);
      var props = await call('getChar', { device: this.device.id, service: this.uuid, char: chr });
      var key = this.device.id + '|' + this.uuid + '|' + chr;
      var c = chars.get(key);
      if (!c) { c = new BluetoothRemoteGATTCharacteristic(this, chr, props); chars.set(key, c); }
      return c;
    }
  }

  class BluetoothRemoteGATTCharacteristic extends EventTarget {
    constructor(service, uuid, props) {
      super();
      this.service = service;
      this.uuid = uuid;
      this.properties = props || {};
      this.value = null;
    }
    _args(extra) {
      return Object.assign({ device: this.service.device.id, service: this.service.uuid, char: this.uuid }, extra || {});
    }
    async startNotifications() { await call('notify', this._args({ on: true })); return this; }
    async stopNotifications() { await call('notify', this._args({ on: false })); return this; }
    async readValue() { this.value = toView(await call('read', this._args())); return this.value; }
    async writeValue(data) { await call('write', this._args({ data: toB64(data), withResponse: true })); }
    async writeValueWithResponse(data) { await call('write', this._args({ data: toB64(data), withResponse: true })); }
    async writeValueWithoutResponse(data) { await call('write', this._args({ data: toB64(data), withResponse: false })); }
  }

  /* ---------------- navigator.bluetooth ---------------- */
  var bluetooth = {
    getAvailability: function () { return call('availability').then(function (v) { return !!v; }); },
    requestDevice: async function (options) {
      options = options || {};
      var filters = (options.filters || []).map(function (f) {
        var o = {};
        if (f.services && f.services.length) o.services = f.services.map(canon);
        if (f.name) o.name = String(f.name);
        if (f.namePrefix) o.namePrefix = String(f.namePrefix);
        return o;
      });
      if (!options.acceptAllDevices && !filters.length) throw new TypeError('Servono filters oppure acceptAllDevices');
      var r = await call('request', {
        filters: filters,
        acceptAll: !!options.acceptAllDevices,
        optionalServices: (options.optionalServices || []).map(canon),
      });
      var d = devices.get(r.id);
      if (!d) { d = new BluetoothDevice(r.id, r.name); devices.set(r.id, d); }
      else if (r.name) d.name = r.name;
      return d;
    },
    addEventListener: function () {},
    removeEventListener: function () {},
  };
  Object.defineProperty(navigator, 'bluetooth', { value: bluetooth, configurable: true });
  window.BluetoothUUID = { getService: canon, getCharacteristic: canon, getDescriptor: canon, canonicalUUID: function (n) { return canon(Number(n)); } };

  /* ---------------- Risposte e notifiche che arrivano dall'app ---------------- */
  window.__bleNative = {
    resolve: function (id, value) {
      var p = pending.get(id);
      if (p) { pending.delete(id); p.resolve(value); }
    },
    reject: function (id, name, message) {
      var p = pending.get(id);
      if (p) { pending.delete(id); p.reject(domErr(name, message)); }
    },
    value: function (dev, svc, chr, b64) {
      var c = chars.get(dev + '|' + svc + '|' + chr);
      if (!c) return;
      c.value = toView(b64);
      c.dispatchEvent(new Event('characteristicvaluechanged'));
    },
    disconnected: function (dev) {
      Array.from(chars.keys()).forEach(function (k) { if (k.indexOf(dev + '|') === 0) chars.delete(k); });
      var d = devices.get(dev);
      if (!d) return;
      d.gatt.connected = false;
      d.dispatchEvent(new Event('gattserverdisconnected'));
    },
  };

  /* ---------------- Condivisione file (backup), se WebKit non la offre ---------------- */
  if (!navigator.canShare && mh.share) {
    navigator.canShare = function (d) { return !!(d && d.files && d.files.length); };
    navigator.share = async function (d) {
      var f = d && d.files && d.files[0];
      if (!f) throw domErr('AbortError', 'Niente da condividere');
      mh.share.postMessage({ name: f.name || 'cyclette.json', text: await f.text() });
    };
  }
})();
