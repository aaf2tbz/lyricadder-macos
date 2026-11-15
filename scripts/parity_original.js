#!/usr/bin/env node
// Runs the ORIGINAL lyricadder renderer code (mainScripts.js / midiScripts.js extracted from app.asar)
// headlessly with tiny DOM/jQuery shims, so its results can be diffed against the native port.
//
//   node parity_original.js <extracted-app-dir> chart <file.chart> <lyrics.txt> <out.chart>
//   node parity_original.js <extracted-app-dir> midi-lyrics <file.mid>
//
// Nothing in the original is modified; its functions are called the same way the UI's buttons call them.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const vm = require("vm");

const abs = (p) => (p ? path.resolve(p) : p);
const argv = process.argv.slice(2);
const [appDir, mode, file, lyricsPath, outPath] = [abs(argv[0]), argv[1], abs(argv[2]), abs(argv[3]), abs(argv[4])];
if (!appDir || !mode || !file) {
  console.error("usage: parity_original.js <app-dir> chart|midi-lyrics <file> [lyrics.txt] [out]");
  process.exit(2);
}

// The original reads/writes ../lyricAdder_backups/config.json relative to the CWD: give it a sandbox.
const work = fs.mkdtempSync(path.join(os.tmpdir(), "lyricadder-parity-"));
const cwd = path.join(work, "app");
fs.mkdirSync(cwd);
fs.mkdirSync(path.join(work, "lyricAdder_backups"));
fs.writeFileSync(path.join(work, "lyricAdder_backups", "config.json"),
  JSON.stringify({ pathToBackupFolder: "../lyricAdder_backups", version: "1.2.2", pathToChartFile: "", lyricsInput: "" }));
process.chdir(cwd);

// --- DOM shim: every element is a plain object with the properties the scripts touch.
const elements = {};
function el(id) {
  if (!elements[id]) {
    elements[id] = {
      id, value: "", innerHTML: "", style: {}, files: [], children: [], options: [], scrollTop: 0,
      firstChild: null, setAttribute() {}, removeChild() {}, appendChild() {}, addEventListener() {}, add() {},
    };
  }
  return elements[id];
}
const document = { getElementById: el, createElement: () => el("_tmp" + Math.random()), createTextNode: () => ({}) };
const jq = () => ({ on() { return this; }, click() { return this; }, scroll() { return this; }, linedtextarea() {} });

// Point the "fs" the original uses at a copy so the input file itself is never touched.
const workFile = path.join(work, path.basename(file));
fs.copyFileSync(file, workFile);

function req(name) {
  if (name === "fs") return fs;
  if (name === "jquery") return jq;
  return {}; // soundStuff / difficultyReducer / newChart are not needed for the write path
}

const ctx = { require: req, document, console: { log() {}, error: console.error }, global: {}, Buffer, setTimeout() {}, clearTimeout() {}, module: {}, window: {} };
ctx.global = ctx;
ctx.global.updateLinedTextArea = () => {};
vm.createContext(ctx);

const src = (f) => fs.readFileSync(path.join(appDir, f), "utf8");
vm.runInContext(src("mainScripts.js"), ctx, { filename: "mainScripts.js" });

if (mode === "chart") {
  const lyrics = fs.readFileSync(lyricsPath, "utf8");
  vm.runInContext(`
    config.pathToChartFile = ${JSON.stringify(workFile)};
    HTMLChartFilePath.files = [{ path: config.pathToChartFile }];
    HTMLLyricInput.value = ${JSON.stringify(lyrics)};
    readAndSeparateChartFile();
    readAndModifyEvents();
    readLyricInput();
  `, ctx);
  const ok = vm.runInContext("testReadChartAndLrics()", ctx);
  const report = {
    phrases: vm.runInContext("eventsPhraseArray.map(p => p.length)", ctx),
    syllables: vm.runInContext("lyricsInputArray.map(p => p.length)", ctx),
    lyricsFromChart: vm.runInContext("getLyricsFromChart()", ctx),
    writable: !!ok,
    error: elements.cautionMessage ? elements.cautionMessage.innerHTML : "",
  };
  if (ok) {
    vm.runInContext("modifyEventsAndOriginalChart()", ctx);
    fs.writeFileSync(outPath, vm.runInContext('modifiedOutputFile.join("\\r\\n")', ctx));
  }
  console.log(JSON.stringify(report));
} else if (mode === "midi-lyrics") {
  vm.runInContext(src("midiScripts.js"), ctx, { filename: "midiScripts.js" });
  // Original reads the file name from a Windows path; give it one with backslashes.
  vm.runInContext(`
    HTMLMidiFile.files = [{ path: ${JSON.stringify(workFile)} }];
    HTMLMIDIFilePath.files = HTMLMidiFile.files;
    HTMLLyricInput.value = "-";
    midiParse();
    getLyricsFromMIDIButton();
  `, ctx);
  console.log(JSON.stringify({
    phrases: vm.runInContext("globalSeparatedLyrics.map(p => p.events.length)", ctx),
    lyrics: elements.lyricsInputArea.value.trim(),
  }));
} else {
  console.error("unknown mode " + mode);
  process.exit(2);
}
fs.rmSync(work, { recursive: true, force: true });
