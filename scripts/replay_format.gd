class_name ReplayFormat
extends RefCounted
##
## THE REPLAY FILE, BYTE BY BYTE.
##
## One recording is one append-only file, `<id>.bbreplay`, plus a small
## editable sidecar `<id>.json` (title, favourite, tags — see ReplayStore).
##
##   file header   8 bytes  "BBREPLAY"
##                 u32      format version (VERSION)
##                 u32      reserved (0)
##   chunk*        36-byte chunk header + zstd-compressed payload
##
## CHUNK HEADER (little endian):
##   u32 magic 'BBCK' · u8 type · u8×3 reserved · f64 t0 · f64 t1
##   u32 raw length · u32 compressed length · u32 hash of the compressed bytes
##
## CHUNK TYPES
##   HEADER      JSON: who, what, where — roster, element table, rates
##   SAMPLES     var_to_bytes([meta, PackedFloat32Array]) — one block of
##               lightweight playback samples (see ReplayRecorder for layout)
##   CHECKPOINT  JSON: a complete Snapshot.capture() of the world at t0,
##               restorable exactly like a saved situation
##   EVENTS      JSON: gameplay events that happened during the last block
##   FINAL       JSON: outcome, duration, recorded score — written once, last
##
## WHY APPEND-ONLY. Nothing already written is ever rewritten, so a crash, a
## power cut or a full disk can only cost the chunk being written at that
## moment. The reader scans chunk headers from the front and stops cleanly at
## the first incomplete or damaged one: everything before it plays. A file
## with no FINAL chunk is reported as RECOVERED, never as a finished run.
##
## Readers never decode a payload to list a file: `scan()` touches headers
## only, so the library and the timeline can index an hour-long recording
## without loading it.
##

const MAGIC := "BBREPLAY"
const VERSION := 1
const CHUNK_MAGIC := 0x4B434242        # "BBCK" little endian
const CHUNK_HEADER_BYTES := 36
const FILE_HEADER_BYTES := 16
const EXT := ".bbreplay"

enum Chunk { HEADER = 1, SAMPLES = 2, CHECKPOINT = 3, EVENTS = 4, FINAL = 5 }

## How many payloads have been decoded in this process, for tests that must
## prove the library never opened a recording just to list it.
static var decode_count := 0

# ==================================================================== write ==

static func write_file_header(f: FileAccess) -> bool:
	var ok := f.store_buffer(MAGIC.to_ascii_buffer())
	ok = f.store_32(VERSION) and ok
	ok = f.store_32(0) and ok
	return ok and f.get_error() == OK

## One chunk as bytes: header + compressed payload. The file writer and the
## online room both use this, so a chunk streamed to a player is byte-for-byte
## the chunk an offline recording would have written.
static func encode_chunk(type: int, t0: float, t1: float, raw: PackedByteArray) -> PackedByteArray:
	var comp := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var h := PackedByteArray()
	h.resize(CHUNK_HEADER_BYTES)
	h.encode_u32(0, CHUNK_MAGIC)
	h.encode_u8(4, type)
	h.encode_double(8, t0)
	h.encode_double(16, t1)
	h.encode_u32(24, raw.size())
	h.encode_u32(28, comp.size())
	h.encode_u32(32, _hash(comp))
	return h + comp

## Check a chunk that arrived over the network before it is written: the
## header must be ours, the lengths must add up and the checksum must match.
## Returns "" or what is wrong.
static func check_chunk(bytes: PackedByteArray) -> String:
	if bytes.size() < CHUNK_HEADER_BYTES:
		return "too short"
	if bytes.decode_u32(0) != CHUNK_MAGIC:
		return "not a chunk"
	var type := bytes.decode_u8(4)
	if type < Chunk.HEADER or type > Chunk.FINAL:
		return "unknown chunk type"
	var t0 := bytes.decode_double(8)
	var t1 := bytes.decode_double(16)
	if not (is_finite(t0) and is_finite(t1)) or t1 < t0 - 0.0001 or t0 < 0.0:
		return "bad times"
	var raw := bytes.decode_u32(24)
	var comp := bytes.decode_u32(28)
	if raw > 64 * 1024 * 1024 or comp != bytes.size() - CHUNK_HEADER_BYTES:
		return "bad lengths"
	if _hash(bytes.slice(CHUNK_HEADER_BYTES)) != bytes.decode_u32(32):
		return "checksum mismatch"
	return ""

## Append one chunk. Returns the number of bytes written, or -1 on failure.
static func write_chunk(f: FileAccess, type: int, t0: float, t1: float,
		raw: PackedByteArray) -> int:
	return write_encoded(f, encode_chunk(type, t0, t1, raw))

static func write_encoded(f: FileAccess, chunk: PackedByteArray) -> int:
	var ok := f.store_buffer(chunk)
	if not ok or f.get_error() != OK:
		return -1
	return chunk.size()

static func json_bytes(v: Variant) -> PackedByteArray:
	return JSON.stringify(v).to_utf8_buffer()

## A 32-bit checksum of a byte string: the first four bytes of its MD5,
## computed natively. Enough to notice a truncated, zeroed or overwritten
## payload; not a security measure.
static func _hash(b: PackedByteArray) -> int:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	if not b.is_empty():
		ctx.update(b)
	var d := ctx.finish()
	return d.decode_u32(0)

# ===================================================================== read ==

## Index a replay file from its chunk headers alone.
##
## Returns {
##   error:     "" or a sentence for a person (unreadable / not a replay /
##              newer version) — when set, nothing else is meaningful
##   header:    the HEADER chunk's dictionary
##   chunks:    [{type, t0, t1, at, raw, comp, hash}] in file order
##   final:     the FINAL chunk's dictionary, or {} if the run never finished
##   complete:  true only with a FINAL chunk
##   damaged:   a sentence if scanning stopped early at a bad chunk
##   duration:  the last playable sample time
##   bytes:     file size
## }
static func scan(path: String) -> Dictionary:
	var out := {"error": "", "header": {}, "chunks": [], "final": {},
		"complete": false, "damaged": "", "duration": 0.0, "bytes": 0,
		"version": 0}
	if not FileAccess.file_exists(path):
		out["error"] = "The recording file is missing."
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		out["error"] = "The recording file could not be opened."
		return out
	var size := f.get_length()
	out["bytes"] = size
	if size < FILE_HEADER_BYTES:
		out["error"] = "The recording file is empty or cut short."
		return out
	var magic := f.get_buffer(8).get_string_from_ascii()
	if magic != MAGIC:
		out["error"] = "That file is not a BIOBUZZ replay."
		return out
	var ver := f.get_32()
	f.get_32()
	out["version"] = ver
	if ver > VERSION:
		out["error"] = ("That replay was recorded by a newer version of the game "
			+ "(format %d; this version reads up to %d).") % [ver, VERSION]
		return out
	if ver < 1:
		out["error"] = "That replay's format version is not valid."
		return out

	var chunks: Array = []
	while true:
		var at := f.get_position()
		if at >= size:
			break
		if size - at < CHUNK_HEADER_BYTES:
			out["damaged"] = "The recording ends part-way through a block."
			break
		if f.get_32() != CHUNK_MAGIC:
			out["damaged"] = "The recording is damaged after %s." % _clock(
				float(chunks[-1]["t1"]) if not chunks.is_empty() else 0.0)
			break
		var type := f.get_8()
		f.get_8()
		f.get_8()
		f.get_8()
		var t0 := f.get_double()
		var t1 := f.get_double()
		var raw := f.get_32()
		var comp := f.get_32()
		var hsh := f.get_32()
		var body := f.get_position()
		if body + comp > size:
			out["damaged"] = "The recording ends part-way through a block."
			break
		if not (is_finite(t0) and is_finite(t1)) or t1 < t0 - 0.0001 or raw > 64 * 1024 * 1024:
			out["damaged"] = "The recording has a damaged block header."
			break
		chunks.append({"type": type, "t0": t0, "t1": t1, "at": body,
			"raw": raw, "comp": comp, "hash": hsh})
		f.seek(body + comp)
	out["chunks"] = chunks

	var header_entry: Dictionary = {}
	for c in chunks:
		if int(c["type"]) == Chunk.HEADER:
			header_entry = c
			break
	if header_entry.is_empty():
		out["error"] = "The recording has no readable header."
		return out
	var h: Variant = read_json(f, header_entry)
	if not (h is Dictionary) or String((h as Dictionary).get("format", "")) != "biobuzz.replay":
		out["error"] = "The recording's header is damaged."
		return out
	out["header"] = h
	for c2 in chunks:
		match int(c2["type"]):
			Chunk.SAMPLES:
				out["duration"] = maxf(float(out["duration"]), float(c2["t1"]))
			Chunk.FINAL:
				var fin: Variant = read_json(f, c2)
				if fin is Dictionary:
					out["final"] = fin
					out["complete"] = true
	f.close()
	return out

## Just the 16-byte file signature: "" when it is a replay this version can
## read, otherwise the same sentence scan() would give.
static func peek_header(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "The recording file could not be opened."
	if f.get_length() < FILE_HEADER_BYTES:
		return "The recording file is empty or cut short."
	if f.get_buffer(8).get_string_from_ascii() != MAGIC:
		return "That file is not a BIOBUZZ replay."
	var ver := f.get_32()
	if ver > VERSION:
		return ("That replay was recorded by a newer version of the game "
			+ "(format %d; this version reads up to %d).") % [ver, VERSION]
	if ver < 1:
		return "That replay's format version is not valid."
	return ""

## Decode one chunk's payload bytes, or an empty array if it is damaged.
static func read_raw(f: FileAccess, c: Dictionary) -> PackedByteArray:
	f.seek(int(c["at"]))
	var comp := f.get_buffer(int(c["comp"]))
	if comp.size() != int(c["comp"]) or _hash(comp) != int(c["hash"]):
		return PackedByteArray()
	var raw := comp.decompress(int(c["raw"]), FileAccess.COMPRESSION_ZSTD)
	if raw.size() != int(c["raw"]):
		return PackedByteArray()
	decode_count += 1
	return raw

static func read_json(f: FileAccess, c: Dictionary) -> Variant:
	var raw := read_raw(f, c)
	if raw.is_empty():
		return null
	return JSON.parse_string(raw.get_string_from_utf8())

## A SAMPLES chunk as [meta, PackedFloat32Array], or [] if it is damaged.
## Objects are never allowed through bytes_to_var.
static func read_samples(f: FileAccess, c: Dictionary) -> Array:
	var raw := read_raw(f, c)
	if raw.is_empty():
		return []
	var v: Variant = bytes_to_var(raw)
	if not (v is Array) or (v as Array).size() < 2:
		return []
	var a: Array = v
	if not (a[0] is Dictionary) or not (a[1] is PackedFloat32Array):
		return []
	return a

static func _clock(t: float) -> String:
	return "%d:%04.1f" % [int(t) / 60, fmod(t, 60.0)]
