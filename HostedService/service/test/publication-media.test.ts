import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { deflateSync } from "node:zlib";
import test from "node:test";

import {
  PublicationArchiveValidationError,
  validatePublishedJPEG,
  validatePublishedPNG,
} from "../src/publication/archive-validator.js";

test("published PNG validation reaches bounded zlib/filter decoding rather than accepting CRC-valid IDAT carrier bytes", async () => {
  const valid = pngWithScanlines(Uint8Array.from([
    0, 0x11, 0x22, 0x33,
    1, 0x01, 0x02, 0x03,
    2, 0x04, 0x05, 0x06,
    3, 0x07, 0x08, 0x09,
    4, 0x0a, 0x0b, 0x0c,
  ]));
  await assert.doesNotReject(() => validatePublishedPNG(valid), "positive control traverses all five PNG filter codes");

  const invalidDeflate = pngWithIDAT(Uint8Array.of(0x00));
  await assert.rejects(
    () => validatePublishedPNG(invalidDeflate),
    (error: unknown) => error instanceof PublicationArchiveValidationError && error.code === "media",
    "a CRC-valid but non-deflate IDAT must be rejected only by the real bounded inflate path",
  );
});

test("publication image decoders reject EXIF/XMP/HTML/SVG and trailing carriers rather than relying on file extensions", async () => {
  const png = pngWithScanlines(Uint8Array.from([
    0, 0x11, 0x22, 0x33,
    0, 0x44, 0x55, 0x66,
    0, 0x77, 0x88, 0x99,
    0, 0xaa, 0xbb, 0xcc,
    0, 0xdd, 0xee, 0xff,
  ]));
  for (const carrier of [chunk("eXIf", Buffer.from("GPS:42.0,-71.0", "ascii")), chunk("iTXt", Buffer.from("XML:com.adobe.xmp private", "ascii")), chunk("tEXt", Buffer.from("<svg><script>alert(1)</script></svg>", "ascii"))]) {
    await assert.rejects(() => validatePublishedPNG(insertBeforeIEND(png, carrier)), mediaFailure, "a CRC-valid ancillary image chunk cannot carry private metadata or browser content");
  }
  await assert.rejects(() => validatePublishedPNG(join([png, Buffer.from("<html>trailer</html>", "ascii")])), mediaFailure, "bytes after PNG IEND are not ignored as a polyglot trailer");

  const jpeg = baselineJPEG({ width: 1, height: 1, samplings: [0x11] });
  for (const carrier of [segment(0xe1, Buffer.from("Exif\u0000\u0000GPSLatitude", "ascii")), segment(0xe1, Buffer.from("http://ns.adobe.com/xap/1.0/\u0000<private/>", "ascii")), segment(0xe0, Buffer.from("<html>polyglot</html>", "ascii"))]) {
    assert.throws(() => validatePublishedJPEG(insertAfterSOI(jpeg, carrier)), mediaFailure, "JPEG APP metadata is forbidden before it can reach a browser or portal renderer");
  }
  assert.throws(() => validatePublishedJPEG(join([jpeg, Buffer.from("<svg/>", "ascii")])), mediaFailure, "JPEG trailing bytes are decoded through EOI and cannot be a renamed private archive");
});

test("published JPEG validation decodes the actual Core stuffed-FF/DRI baseline JPEG instead of marker-scanning it", () => {
  const jpeg = roomFixtureJPEG();
  assert.doesNotThrow(() => validatePublishedJPEG(jpeg), "positive control is the real Core-produced 4:2:0 JPEG with DRI and stuffed FF entropy");

  const badStuffing = Uint8Array.from(jpeg);
  const stuffing = badStuffing.findIndex((value, index) => value === 0xff && badStuffing[index + 1] === 0x00);
  assert.notEqual(stuffing, -1, "positive control reaches a stuffed FF byte in the Core entropy stream");
  badStuffing[stuffing + 1] = 0x01;
  assert.throws(
    () => validatePublishedJPEG(badStuffing),
    (error: unknown) => error instanceof PublicationArchiveValidationError && error.code === "media",
    "an entropy FF not followed by valid stuffing/restart/EOI must fail",
  );
});

test("published PNG decoder consumes exactly one zlib stream, traverses Adam7 passes, and rejects truncation, surplus output, and invalid filters", async () => {
  const adam7 = pngWithIDAT(Uint8Array.from(deflateSync(adam7Scanlines(5, 5))), 5, 5, 1);
  await assert.doesNotReject(() => validatePublishedPNG(adam7), "the positive control reaches every non-empty Adam7 pass");

  const raw = Uint8Array.from([0, 1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0, 13, 14, 15]);
  const member = Uint8Array.from(deflateSync(raw));
  await assert.rejects(() => validatePublishedPNG(pngWithIDAT(join([member, Uint8Array.from(deflateSync(Uint8Array.of(1)))]))), mediaFailure, "a second zlib member is unconsumed carrier data");
  await assert.rejects(() => validatePublishedPNG(pngWithIDAT(member.subarray(0, -1))), mediaFailure, "truncated zlib input must not yield a partial image");
  await assert.rejects(() => validatePublishedPNG(pngWithIDAT(Uint8Array.from(deflateSync(Uint8Array.of(0, 1, 2, 3))))), mediaFailure, "a complete but short zlib member reaches the decoder's exact scanline-consumption guard");
  await assert.rejects(() => validatePublishedPNG(pngWithIDAT(Uint8Array.from(deflateSync(Uint8Array.from([...raw, 0]))))), mediaFailure, "decoded bytes beyond the exact IHDR scanline budget are rejected");
  await assert.rejects(() => validatePublishedPNG(pngWithIDAT(Uint8Array.from(deflateSync(Uint8Array.from([5, 1, 2, 3]))))), mediaFailure, "filter codes outside 0...4 are reached by the decoder");
});

test("published baseline JPEG decoder covers grayscale, 4:4:4, 4:2:0, restart cycling/wrap, and entropy negative controls", () => {
  for (const candidate of [
    baselineJPEG({ width: 1, height: 1, samplings: [0x11] }),
    baselineJPEG({ width: 1, height: 1, samplings: [0x11, 0x11, 0x11] }),
    baselineJPEG({ width: 1, height: 1, samplings: [0x22, 0x11, 0x11] }),
    baselineJPEG({ width: 160, height: 1, samplings: [0x22, 0x11, 0x11], restartInterval: 1 }),
  ]) assert.doesNotThrow(() => validatePublishedJPEG(candidate));

  const gray = baselineJPEG({ width: 1, height: 1, samplings: [0x11] });
  assert.throws(() => validatePublishedJPEG(Uint8Array.from(gray.subarray(0, -1))), mediaFailure, "truncated entropy/EOI is not accepted");
  assert.throws(() => validatePublishedJPEG(join([gray, Uint8Array.of(0)])), mediaFailure, "bytes after EOI are rejected");
  assert.throws(() => validatePublishedJPEG(insertAfterSOI(gray, Uint8Array.of(0xff, 0xe0, 0, 2))), mediaFailure, "APP segments are not a publication metadata carrier");

  const padding = Uint8Array.from(gray); padding[padding.length - 3] = (padding[padding.length - 3] ?? 0) & 0xfe;
  assert.throws(() => validatePublishedJPEG(padding), mediaFailure, "non-one entropy padding is checked after the final MCU");

  const restart = baselineJPEG({ width: 32, height: 1, samplings: [0x22, 0x11, 0x11], restartInterval: 1 });
  const restartByte = restart.findIndex((value, index) => value === 0xff && restart[index + 1] === 0xd0);
  assert.notEqual(restartByte, -1, "positive control reaches an RST marker");
  restart[restartByte + 1] = 0xd1;
  assert.throws(() => validatePublishedJPEG(restart), mediaFailure, "restart sequence is bound rather than treated as arbitrary entropy framing");

  const undefinedTable = Uint8Array.from(gray); const sos = markerPayloadOffset(undefinedTable, 0xda); undefinedTable[sos + 2] = 0x33;
  assert.throws(() => validatePublishedJPEG(undefinedTable), mediaFailure, "SOS table selectors bind declared DHT tables");
  const illegalAC = Uint8Array.from(gray); const ac = markerPayloadOffset(illegalAC, 0xc4, 1); illegalAC[ac + 17] = 0x0b;
  assert.throws(() => validatePublishedJPEG(illegalAC), mediaFailure, "illegal AC run/size symbols are rejected before entropy traversal");
  const secondScan = insertBeforeEOI(gray, segment(0xda, Uint8Array.of(1, 1, 0, 0, 63, 0)));
  assert.throws(() => validatePublishedJPEG(secondScan), mediaFailure, "a second scan cannot hide after valid coefficients");
  const extraMCU = replaceEntropy(gray, entropyForBlocks(2));
  assert.throws(() => validatePublishedJPEG(extraMCU), mediaFailure, "extra encoded blocks become invalid final padding rather than ignored bytes");
});

function roomFixtureJPEG(): Uint8Array {
  const archive = Buffer.from(readFileSync("fixtures/publication/room-v2-ai-ready.zip.base64", "utf8").trim(), "base64");
  let offset = 0;
  while (offset + 30 <= archive.byteLength && archive.readUInt32LE(offset) === 0x0403_4b50) {
    const nameLength = archive.readUInt16LE(offset + 26); const extraLength = archive.readUInt16LE(offset + 28); const byteCount = archive.readUInt32LE(offset + 18);
    const name = archive.subarray(offset + 30, offset + 30 + nameLength).toString("utf8");
    const dataOffset = offset + 30 + nameLength + extraLength;
    if (name === "assets/image-original.jpg") return Uint8Array.from(archive.subarray(dataOffset, dataOffset + byteCount));
    offset = dataOffset + byteCount;
  }
  throw new Error("missing Core JPEG fixture");
}

const mediaFailure = (error: unknown): boolean => error instanceof PublicationArchiveValidationError && error.code === "media";

function pngWithScanlines(scanlines: Uint8Array): Uint8Array { return pngWithIDAT(Uint8Array.from(deflateSync(scanlines))); }
function pngWithIDAT(idat: Uint8Array, width = 1, height = 5, interlace = 0): Uint8Array {
  return join([
    Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a),
    chunk("IHDR", Uint8Array.of(width >>> 24, width >>> 16, width >>> 8, width, height >>> 24, height >>> 16, height >>> 8, height, 8, 2, 0, 0, interlace)),
    chunk("IDAT", idat), chunk("IEND", new Uint8Array()),
  ]);
}
function chunk(type: string, data: Uint8Array): Uint8Array {
  const bytes = new Uint8Array(12 + data.byteLength); write32(bytes, 0, data.byteLength); bytes.set(Buffer.from(type, "ascii"), 4); bytes.set(data, 8); write32(bytes, 8 + data.byteLength, crc32(bytes.subarray(4, 8 + data.byteLength))); return bytes;
}
function write32(bytes: Uint8Array, offset: number, value: number): void { bytes[offset] = (value >>> 24) & 0xff; bytes[offset + 1] = (value >>> 16) & 0xff; bytes[offset + 2] = (value >>> 8) & 0xff; bytes[offset + 3] = value & 0xff; }
function join(parts: readonly Uint8Array[]): Uint8Array { const output = new Uint8Array(parts.reduce((length, part) => length + part.byteLength, 0)); let offset = 0; for (const part of parts) { output.set(part, offset); offset += part.byteLength; } return output; }
const CRC = Array.from({ length: 256 }, (_, index) => { let value = index; for (let bit = 0; bit < 8; bit += 1) value = (value & 1) === 1 ? (value >>> 1) ^ 0xedb8_8320 : value >>> 1; return value >>> 0; });
function crc32(bytes: Uint8Array): number { let value = 0xffff_ffff; for (const byte of bytes) value = (value >>> 8) ^ (CRC[(value ^ byte) & 0xff] ?? 0); return (value ^ 0xffff_ffff) >>> 0; }

function adam7Scanlines(width: number, height: number): Uint8Array {
  const values: number[] = []; const passes: readonly (readonly [number, number, number, number])[] = [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]];
  for (const [x, y, dx, dy] of passes) {
    const columns = width <= x ? 0 : Math.floor((width - x - 1) / dx) + 1; const rows = height <= y ? 0 : Math.floor((height - y - 1) / dy) + 1;
    for (let row = 0; row < rows; row += 1) { values.push(0); for (let column = 0; column < columns * 3; column += 1) values.push((row + column) & 0xff); }
  }
  return Uint8Array.from(values);
}

function baselineJPEG(input: { readonly width: number; readonly height: number; readonly samplings: readonly number[]; readonly restartInterval?: number }): Uint8Array {
  const components = input.samplings.map((sampling, index) => ({ id: index + 1, sampling })); const maximumHorizontal = Math.max(...components.map((component) => component.sampling >>> 4)); const maximumVertical = Math.max(...components.map((component) => component.sampling & 0x0f));
  const mcus = Math.ceil(input.width / (maximumHorizontal * 8)) * Math.ceil(input.height / (maximumVertical * 8)); const blocksPerMCU = components.reduce((total, component) => total + (component.sampling >>> 4) * (component.sampling & 0x0f), 0);
  const entropy: number[] = [];
  for (let mcu = 0; mcu < mcus; mcu += 1) {
    entropy.push(...entropyForBlocks(blocksPerMCU));
    if (input.restartInterval !== undefined && mcu + 1 < mcus && (mcu + 1) % input.restartInterval === 0) entropy.push(0xff, 0xd0 + (Math.floor((mcu + 1) / input.restartInterval) - 1) % 8);
  }
  return join([
    Uint8Array.of(0xff, 0xd8),
    segment(0xdb, Uint8Array.from([0, ...Array(64).fill(1)])),
    segment(0xc4, Uint8Array.from([0, 1, ...Array(15).fill(0), 0])),
    segment(0xc4, Uint8Array.from([0x10, 1, ...Array(15).fill(0), 0])),
    segment(0xc0, Uint8Array.from([8, input.height >>> 8, input.height, input.width >>> 8, input.width, components.length, ...components.flatMap((component) => [component.id, component.sampling, 0])])),
    ...(input.restartInterval === undefined ? [] : [segment(0xdd, Uint8Array.of(input.restartInterval >>> 8, input.restartInterval))]),
    segment(0xda, Uint8Array.from([components.length, ...components.flatMap((component) => [component.id, 0]), 0, 63, 0])),
    Uint8Array.from(entropy), Uint8Array.of(0xff, 0xd9),
  ]);
}

function entropyForBlocks(blockCount: number): number[] {
  const bits = Array.from({ length: blockCount * 2 }, () => 0); while (bits.length % 8 !== 0) bits.push(1);
  const output: number[] = []; for (let offset = 0; offset < bits.length; offset += 8) { const value = bits.slice(offset, offset + 8).reduce((total, bit) => (total << 1) | bit, 0); output.push(value); if (value === 0xff) output.push(0); }
  return output;
}
function segment(marker: number, payload: Uint8Array): Uint8Array { return Uint8Array.from([0xff, marker, (payload.byteLength + 2) >>> 8, payload.byteLength + 2, ...payload]); }
function markerPayloadOffset(bytes: Uint8Array, wanted: number, occurrence = 0): number { let offset = 2; let found = 0; while (offset + 4 <= bytes.byteLength) { if (bytes[offset] !== 0xff) throw new Error("unexpected entropy"); const marker = bytes[offset + 1]; const length = ((bytes[offset + 2] ?? 0) << 8) | (bytes[offset + 3] ?? 0); if (marker === wanted && found++ === occurrence) return offset + 4; offset += 2 + length; } throw new Error(`missing marker ${wanted}`); }
function insertAfterSOI(bytes: Uint8Array, addition: Uint8Array): Uint8Array { return join([bytes.subarray(0, 2), addition, bytes.subarray(2)]); }
function insertBeforeIEND(bytes: Uint8Array, addition: Uint8Array): Uint8Array { return join([bytes.subarray(0, -12), addition, bytes.subarray(-12)]); }
function insertBeforeEOI(bytes: Uint8Array, addition: Uint8Array): Uint8Array { return join([bytes.subarray(0, -2), addition, bytes.subarray(-2)]); }
function replaceEntropy(bytes: Uint8Array, entropy: readonly number[]): Uint8Array { const sos = markerPayloadOffset(bytes, 0xda); const start = sos + (((bytes[sos - 2] ?? 0) << 8) | (bytes[sos - 1] ?? 0)) - 2; return join([bytes.subarray(0, start), Uint8Array.from(entropy), Uint8Array.of(0xff, 0xd9)]); }
