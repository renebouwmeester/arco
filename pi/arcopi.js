#!/usr/bin/env node
// Arco Pi (werknaam, 22 okt 2026) — de Pi als USB-geluidskaart voor de iPhone, en wat de iPhone speelt naar een
// UPnP-streamer (Roon volgt). René: "eerst de webpagina op de Pi en de doorlopende stroom".
//
// De iPhone ziet de Pi als USB-DAC (UAC2-gadget, ~/arco-gadget.sh) en zet de rate zelf per nummer (gemeten 22 okt:
// 44,1 → 96 → 192); de samples komen onaangeroerd binnen (het volume gaat via de gadget-regeling). Deze dienst leest wat
// binnenkomt en maakt er runs van zoals Arco op de Mac (Slices.swift): één groeiende WAV per stuk op één rate, die de
// streamer ophaalt terwijl hij groeit. Een nieuwe run bij elke start en elke rate-wissel; de iPhone sluit de stroom
// (rate 0) bij een pauze, een skip en tussen nummers met een andere rate.
//
// Een webpagina op :9310 kiest het doel (een UPnP-renderer, of uit); de keuze blijft bewaard.
"use strict";
const http = require("http"), dgram = require("dgram"), fs = require("fs"), os = require("os"), path = require("path");
const { spawn, execFile } = require("child_process");

const POORT = 9310;
const MAP = path.join(os.homedir(), ".cache", "arcopi");
const KEUZE = path.join(os.homedir(), ".config", "arcopi", "doel.json");
const KAART = "UAC2Gadget";
// De voorsprong per streamer (22 okt 2026, René: "maak de voorsprong per streamer instelbaar, KEF op 1 s"): zoveel
// seconden geschreven vóór de renderer begint. Standaard 3 (de Ellipse en de Mu-so hebben dat nodig), de KEF 1. Na een
// skip hoor je zoveel seconden van het oude nummer na.
const VOORSPRONG_STANDAARD = 3;
const VOORSPRONGEN = path.join(os.homedir(), ".config", "arcopi", "voorsprong.json");
let voorsprongen = (() => { try { return JSON.parse(fs.readFileSync(VOORSPRONGEN, "utf8")); } catch { return {}; } })();
const voorsprong = () => (doel && voorsprongen[doel.id]) || VOORSPRONG_STANDAARD;
const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a);

fs.rmSync(MAP, { recursive: true, force: true }); fs.mkdirSync(MAP, { recursive: true });
fs.mkdirSync(path.dirname(KEUZE), { recursive: true });
let doel = (() => { try { return JSON.parse(fs.readFileSync(KEUZE, "utf8")); } catch { return null; } })();   // { id, naam, location }

// ---- de runs -----------------------------------------------------------------------------------------------------
// Een run: een bestand dat groeit, met een WAV-kop die een lange lengte belooft (3 uur, binnen de 4 GB van een WAV).
const sessie = Math.random().toString(36).slice(2, 8);
let teller = 0, run = null;   // { nr, rate, bestand, fd, geschreven (bytes), lezers: Set, dicht }
// De run die de renderer nu speelt, en tot wanneer hij nog speelt na een gesloten run (hij loopt de voorsprong achter).
let speelt = null, speeltTot = 0;
const runs = new Map();
const capaciteit = (rate) => Math.min(rate * 3 * 3600, Math.floor((2 ** 32 - 1 - 36) / 6));
function wavKop(rate, frames) {
  const b = Buffer.alloc(44), data = frames * 6;
  b.write("RIFF", 0); b.writeUInt32LE(36 + data, 4); b.write("WAVE", 8); b.write("fmt ", 12); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); b.writeUInt16LE(2, 22); b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate * 6, 28);
  b.writeUInt16LE(6, 32); b.writeUInt16LE(24, 34); b.write("data", 36); b.writeUInt32LE(data, 40);
  return b;
}
function nieuweRun(rate) {
  sluitRun();
  teller++;
  const bestand = path.join(MAP, `run-${teller}.pcm`);
  run = { nr: teller, rate, bestand, fd: fs.openSync(bestand, "w+"), geschreven: 0, lezers: new Set(), dicht: false, gespeeld: false };
  runs.set(teller, run);
  for (const [n, r] of runs) if (n < teller - 1) { for (const l of r.lezers) l.destroy(); try { fs.closeSync(r.fd); fs.rmSync(r.bestand); } catch {} runs.delete(n); }
  log(`run ${run.nr} begint op ${rate} Hz`);
}
// Dicht: de lezers krijgen de rest en dan het einde van het bestand (de kop beloofde 3 uur) — de renderer gaat dan door
// naar wat als volgende klaarstaat (SetNext), of stopt.
function sluitRun() {
  if (!run) return;
  run.dicht = true; for (const l of run.lezers) pomp(run, l);
  if (speelt === run) speeltTot = Date.now() + (voorsprong() + 1) * 1000;
  run = null;
}
function schrijf(buf) {
  if (!run) return;
  fs.writeSync(run.fd, buf, 0, buf.length, run.geschreven);
  run.geschreven += buf.length;
  for (const l of run.lezers) pomp(run, l);
  // Speelt de renderer nog de vorige run (de iPhone wisselde van rate of van nummer): deze als volgende, meteen — hij gaat
  // er zelf naartoe als de vorige uit is. Anders (een start, of na een pauze): spelen met de voorsprong.
  if (!run.gespeeld && speelt && speelt !== run && Date.now() < speeltTot) { run.gespeeld = true; zetVolgende(run); }
  if (!run.gespeeld && run.geschreven >= voorsprong() * run.rate * 6) { run.gespeeld = true; speel(run); }
}

// ---- de opvang van de gadget ---------------------------------------------------------------------------------------
// De rate die de iPhone instelt (0 = de stroom is dicht), elke 250 ms; bij een andere rate een nieuwe opname.
let opname = null, opnameRate = 0;
function leesRate() {
  execFile("amixer", ["-c", KAART, "cget", "iface=PCM,name=Capture Rate"], (e, uit) => {
    const m = /: values=(\d+)/.exec(uit || ""); const rate = m ? +m[1] : 0;
    if (rate !== opnameRate) wissel(rate);
  });
}
setInterval(leesRate, 250);
function wissel(rate) {
  log(`iPhone: ${rate ? rate + " Hz" : "stroom dicht"}`);
  if (opname) { opname.kill(); opname = null; }
  opnameRate = rate;
  if (!rate) { sluitRun(); return; }   // geen Stop: de renderer speelt zijn voorsprong uit, of gaat door naar de volgende
  nieuweRun(rate);
  opname = spawn("arecord", ["-q", "-D", `hw:${KAART}`, "-f", "S24_3LE", "-c", "2", "-r", String(rate), "-t", "raw"]);
  opname.stdout.on("data", schrijf);
  opname.on("exit", () => { if (opname && opnameRate === rate) { opname = null; log("opname stopte"); } });
}

// ---- de stroom naar de renderer ------------------------------------------------------------------------------------
function beantwoord(r, req, res) {
  const totaal = 44 + capaciteit(r.rate) * 6;
  let vanaf = 0; const m = /bytes=(\d+)-/.exec(req.headers.range || ""); if (m) vanaf = Math.min(totaal, +m[1]);
  const kop = { "Content-Type": "audio/wav", "Accept-Ranges": "bytes", "Connection": "close", "transferMode.dlna.org": "Streaming",
    "contentFeatures.dlna.org": "DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000" };
  if (vanaf > 0) res.writeHead(206, { ...kop, "Content-Range": `bytes ${vanaf}-${totaal - 1}/${totaal}`, "Content-Length": totaal - vanaf });
  else res.writeHead(200, { ...kop, "Content-Length": totaal });
  if (req.method === "HEAD") return res.end();
  const l = res; l.offset = Math.max(0, vanaf - 44); l.bezig = false;
  if (vanaf < 44) l.write(wavKop(r.rate, capaciteit(r.rate)).subarray(vanaf));
  r.lezers.add(l); res.on("close", () => r.lezers.delete(l));
  pomp(r, l);
}
function pomp(r, l) {
  if (l.bezig || l.destroyed) return;
  if (l.offset >= r.geschreven) { if (r.dicht) l.end(); return; }
  const n = Math.min(262144, r.geschreven - l.offset), buf = Buffer.alloc(n);
  fs.readSync(r.fd, buf, 0, n, l.offset); l.offset += n;
  l.bezig = true;
  const vrij = l.write(buf); const verder = () => { l.bezig = false; pomp(r, l); };
  if (vrij) setImmediate(verder); else l.once("drain", verder);
}

// ---- UPnP: renderers vinden en besturen ----------------------------------------------------------------------------
let renderers = new Map();   // id → { id, naam, location, avt, avtType }
// Eén renderer uit zijn beschrijving (het bewaarde adres van het doel: na een herstart hoeft de Pi niet op de zoekronde
// te wachten — 22 okt 2026, 10:00:20: run 1 vond de KEF nog niet en speelde nergens).
async function beschrijf(loc) {
  try {
    const xml = await (await fetch(loc, { signal: AbortSignal.timeout(3000) })).text();
    const tag = (t, x = xml) => (new RegExp(`<${t}>([^<]*)</${t}>`).exec(x) || [])[1];
    const id = tag("UDN"), naam = (tag("friendlyName") || "?").replace(/&amp;/g, "&");
    if (!id || /Sonos|Signalyst|Samsung/i.test(tag("manufacturer") || "")) return null;
    for (const blok of xml.split("<service>").slice(1)) {
      const type = tag("serviceType", blok);
      if (type && type.includes(":service:AVTransport:")) {
        const r = { id, naam, location: loc, avt: new URL(tag("controlURL", blok), tag("URLBase") || loc).href, avtType: type, op: Date.now() };
        renderers.set(id, r); return r;
      }
    }
  } catch {}
  return null;
}
async function doelRenderer() { return (doel && (renderers.get(doel.id) ?? (doel.location && await beschrijf(doel.location)))) || null; }
function zoek() {
  const s = dgram.createSocket("udp4"), gevonden = new Set();
  const q = Buffer.from('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n');
  s.on("message", (m) => { const l = /location:\s*(\S+)/i.exec(m.toString()); if (l) gevonden.add(l[1]); });
  s.bind(() => { s.setMulticastTTL(2); s.send(q, 1900, "239.255.255.250"); s.send(q, 1900, "239.255.255.250"); });
  setTimeout(async () => {
    s.close();
    for (const loc of gevonden) await beschrijf(loc);
    for (const [id, r] of renderers) if (Date.now() - r.op > 10 * 60 * 1000) renderers.delete(id);
  }, 2500);
}
zoek(); setInterval(zoek, 60 * 1000);

async function avt(r, actie, args = "") {
  const body = `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:${actie} xmlns:u="${r.avtType}"><InstanceID>0</InstanceID>${args}</u:${actie}></s:Body></s:Envelope>`;
  try {
    const a = await fetch(r.avt, { method: "POST", body, signal: AbortSignal.timeout(5000),
      headers: { "Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": `"${r.avtType}#${actie}"` } });
    if (!a.ok) log(`upnp: ${r.naam} — ${actie} gaf ${a.status}`);
    return a.ok ? await a.text() : null;
  } catch (e) { log(`upnp: ${r.naam} — ${actie} geen antwoord`); return null; }
}
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
function mijnIP(naar) {
  for (const lijst of Object.values(os.networkInterfaces())) for (const a of lijst) if (a.family === "IPv4" && !a.internal) return a.address;
  return "127.0.0.1";
}
async function speel(r) {
  const d = await doelRenderer();
  if (!d) { log(`run ${r.nr}: geen doel gekozen (of niet gevonden) — niets te spelen`); return; }
  const url = runURL(r);
  if (await avt(d, "SetAVTransportURI", `<CurrentURI>${esc(url)}</CurrentURI><CurrentURIMetaData>${esc(didl(url))}</CurrentURIMetaData>`) === null) return;
  for (let i = 0; i < 12; i++) { if (await avt(d, "Play", "<Speed>1</Speed>") !== null) break; await new Promise((k) => setTimeout(k, 250)); }
  speelt = r; speeltTot = Infinity;
  log(`run ${r.nr} (${r.rate} Hz) → ${d.naam}`);
}
const runURL = (r) => `http://${mijnIP()}:${POORT}/run/${sessie}-${r.nr}.wav`;
function didl(url) {
  return `<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="arcopi" parentID="0" restricted="1"><dc:title>iPhone</dc:title><upnp:artist>Arco Pi</upnp:artist><upnp:class>object.item.audioItem.musicTrack</upnp:class><res protocolInfo="http-get:*:audio/wav:DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000">${esc(url)}</res></item></DIDL-Lite>`;
}
async function zetVolgende(r) {
  const d = await doelRenderer(); if (!d) return;
  const url = runURL(r);
  const ok = await avt(d, "SetNextAVTransportURI", `<NextURI>${esc(url)}</NextURI><NextURIMetaData>${esc(didl(url))}</NextURIMetaData>`) !== null;
  log(`run ${r.nr} (${r.rate} Hz) als volgende → ${d.naam}${ok ? "" : " — geweigerd, dan opnieuw starten"}`);
  if (ok) { speelt = r; speeltTot = Infinity; } else { r.gespeeld = false; }
}

// ---- de webpagina ---------------------------------------------------------------------------------------------------
function pagina() {
  const keuze = (id) => `<select onchange="fetch('/voorsprong',{method:'POST',body:new URLSearchParams({id:'${esc(id)}',s:this.value})})" title="Lead">${[1, 2, 3, 5].map((v) => `<option value="${v}" ${(voorsprongen[id] || VOORSPRONG_STANDAARD) === v ? "selected" : ""}>${v} s</option>`).join("")}</select>`;
  const rij = (id, naam, sub) => `<label><input type="radio" name="doel" value="${esc(id)}" ${doel?.id === id || (!doel && id === "") ? "checked" : ""} onchange="this.form.submit()"> <span>${esc(naam)}</span>${sub ? `<small>${esc(sub)} · lead ${keuze(id)}</small>` : ""}</label>`;
  const lijst = [...renderers.values()].sort((a, b) => a.naam.localeCompare(b.naam));
  const nu = run ? `${run.rate / 1000} kHz` : opnameRate ? `${opnameRate / 1000} kHz` : "Idle";
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Arco Pi</title>
<style>:root{color-scheme:light dark;--bg:#fff;--fg:#111;--sub:#6b6b6b;--line:#ddd}@media (prefers-color-scheme:dark){:root{--bg:#111;--fg:#eee;--sub:#999;--line:#333}}
body{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);font:16px/1.4 -apple-system,system-ui,sans-serif;max-width:520px}
h1{font-size:22px;font-weight:600;margin:0 0 4px}p{color:var(--sub);margin:0 0 20px}label{display:flex;align-items:baseline;gap:10px;padding:12px 0;border-bottom:1px solid var(--line)}
small{color:var(--sub);margin-left:auto}select{font:inherit;color:inherit;background:transparent;border:1px solid var(--line);border-radius:6px;padding:1px 4px}h2{font-size:13px;font-weight:600;color:var(--sub);text-transform:uppercase;letter-spacing:.04em;margin:24px 0 4px}</style>
<h1>Arco Pi</h1><p>From the iPhone: ${esc(nu)}</p><form method="post" action="/doel">
<h2>Play to</h2>${rij("", "Nowhere", "")}${lijst.map((r) => rij(r.id, r.naam, "UPnP")).join("")}
</form><p style="margin-top:20px">${lijst.length ? "" : "Looking for streamers…"}</p></html>`;
}

http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const m = /^\/run\/(\w+)-(\d+)\.wav$/.exec(u.pathname);
  if (m) { const r = m[1] === sessie && runs.get(+m[2]); if (!r) { res.writeHead(404); return res.end(); } return beantwoord(r, req, res); }
  if (u.pathname === "/doel" && req.method === "POST") {
    let body = ""; req.on("data", (d) => body += d);
    req.on("end", () => {
      const id = new URLSearchParams(body).get("doel") || "";
      const oud = doel && renderers.get(doel.id);
      const r = renderers.get(id);
      doel = r ? { id: r.id, naam: r.naam, location: r.location } : null;
      fs.writeFileSync(KEUZE, JSON.stringify(doel));
      log(`doel: ${doel ? doel.naam : "nergens"}`);
      if (oud && oud.id !== doel?.id) avt(oud, "Stop");
      if (run && run.gespeeld) speel(run);   // speelt er al iets: meteen naar het nieuwe doel
      res.writeHead(303, { Location: "/" }); res.end();
    });
    return;
  }
  if (u.pathname === "/voorsprong" && req.method === "POST") {
    let body = ""; req.on("data", (d) => body += d);
    req.on("end", () => {
      const q = new URLSearchParams(body), id = q.get("id"), v = Number(q.get("s"));
      if (id && [1, 2, 3, 5].includes(v)) { voorsprongen[id] = v; fs.writeFileSync(VOORSPRONGEN, JSON.stringify(voorsprongen)); log(`voorsprong: ${renderers.get(id)?.naam ?? id} ${v} s`); }
      res.writeHead(204); res.end();
    });
    return;
  }
  if (u.pathname === "/") { res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" }); return res.end(pagina()); }
  res.writeHead(404); res.end();
}).listen(POORT, () => log(`Arco Pi op :${POORT} — doel: ${doel ? doel.naam : "nergens"}`));
