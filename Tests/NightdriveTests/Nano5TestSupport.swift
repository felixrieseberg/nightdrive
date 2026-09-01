import Foundation
import SQLite3
import Testing

@testable import Nightdrive

/// A fake nano 5G volume plus the Hash72 material its fixtures were signed
/// with, so tests can verify re-signed checkpoint files.
struct Nano5Fixture {
  let fs: IpodFileSystem
  let material: Hash72Material
}

/// Builds a fake nano 5G volume at `root`: a SysInfo with a FireWire GUID, a
/// signed compressed database, HashInfo signing material, and empty SQLite
/// library fixtures.
func makeNano5FileSystem(at root: URL) throws -> Nano5Fixture {
  let fs = IpodFileSystem(volumeURL: root)
  try FileManager.default.createDirectory(at: fs.itunesDir, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: fs.sysInfoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  let guid = try #require(IpodDatabaseSupport.parseGUID("000A27001A2B3C4D"))
  try Data("FirewireGuid: 0x000A27001A2B3C4D\n".utf8).write(to: fs.sysInfoURL)
  var originalCDB = try ITunesCDB.compress(ITunesDBWriter().write(ITunesDatabase()))
  originalCDB = try Hash58.sign(originalCDB, firewireGUID: guid)
  try originalCDB.write(to: fs.compressedDatabaseURL)
  let material = Hash72Material(
    initializationVector: Data((0..<16).map(UInt8.init)),
    randomBytes: Data((40..<52).map(UInt8.init)))
  let hashInfo =
    Data("HASHv0".utf8) + guid + Data(count: 12) + material.randomBytes
    + material.initializationVector
  try FileManager.default.createDirectory(
    at: fs.controlDir.appendingPathComponent("Device"), withIntermediateDirectories: true)
  try hashInfo.write(to: fs.controlDir.appendingPathComponent("Device/HashInfo"))
  try makeNano5SQLiteFixtures(at: fs.sqliteLibraryDirectory)
  return Nano5Fixture(fs: fs, material: material)
}

/// Creates the empty SQLite databases a factory-fresh nano 5G library carries.
func makeNano5SQLiteFixtures(at directory: URL) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try executeSQLite(
    at: directory.appendingPathComponent("Library.itdb"),
    sql: """
      CREATE TABLE db_info (
        pid INTEGER, primary_container_pid INTEGER, audio_language INTEGER,
        subtitle_language INTEGER);
      CREATE TABLE item (
        pid INTEGER PRIMARY KEY, media_kind INTEGER, date_modified INTEGER,
        date_released INTEGER, year INTEGER,
        is_compilation INTEGER, remember_bookmark INTEGER, exclude_from_shuffle INTEGER,
        artwork_status INTEGER, artwork_cache_id INTEGER, start_time_ms REAL,
        stop_time_ms REAL, total_time_ms REAL, track_number INTEGER, track_count INTEGER,
        disc_number INTEGER, disc_count INTEGER, relative_volume INTEGER, genre_id INTEGER,
        album_pid INTEGER, artist_pid INTEGER, composer_pid INTEGER, title TEXT, artist TEXT,
        album TEXT, album_artist TEXT, composer TEXT, sort_title TEXT, sort_artist TEXT,
        sort_album TEXT, sort_album_artist TEXT, sort_composer TEXT, comment TEXT);
      CREATE TABLE avformat_info (
        item_pid INTEGER, sub_id INTEGER, audio_format INTEGER, bit_rate INTEGER,
        sample_rate REAL, duration INTEGER, gapless_heuristic_info INTEGER,
        gapless_encoding_delay INTEGER, gapless_encoding_drain INTEGER,
        gapless_last_frame_resynch INTEGER, analysis_inhibit_flags INTEGER,
        audio_fingerprint INTEGER, volume_normalization_energy INTEGER,
        PRIMARY KEY (item_pid, sub_id));
      CREATE TABLE container (
        pid INTEGER, distinguished_kind INTEGER, date_created INTEGER, date_modified INTEGER,
        name TEXT, name_order INTEGER, parent_pid INTEGER, media_kinds INTEGER,
        workout_template_id INTEGER, is_hidden INTEGER, smart_is_folder INTEGER);
      CREATE TABLE item_to_container (
        item_pid INTEGER, container_pid INTEGER, physical_order INTEGER, shuffle_order INTEGER);
      CREATE TABLE album (
        pid INTEGER, kind INTEGER, artwork_status INTEGER, artwork_item_pid INTEGER,
        artist_pid INTEGER, user_rating INTEGER, name TEXT, name_order INTEGER,
        all_compilations INTEGER, season_number INTEGER);
      CREATE TABLE artist (
        pid INTEGER, kind INTEGER, artwork_status INTEGER, artwork_album_pid INTEGER,
        name TEXT, name_order INTEGER, sort_name TEXT);
      CREATE TABLE composer (pid INTEGER, name TEXT, name_order INTEGER, sort_name TEXT);
      CREATE TABLE genre_map (id INTEGER, genre TEXT, genre_order INTEGER);
      CREATE TABLE location_kind_map (id INTEGER UNIQUE, kind TEXT);
      CREATE TABLE item_to_album (item_pid INTEGER, album_pid INTEGER);
      CREATE TABLE item_to_artist (item_pid INTEGER, artist_pid INTEGER);
      CREATE TABLE item_to_composer (item_pid INTEGER, composer_pid INTEGER);
      CREATE TABLE container_seed (container_pid INTEGER);
      CREATE TABLE video_info (item_pid INTEGER);
      CREATE TABLE video_characteristics (item_pid INTEGER);
      CREATE TABLE store_info (item_pid INTEGER);
      CREATE TABLE podcast_info (item_pid INTEGER);
      CREATE TABLE category_map (id INTEGER);
      """)
  try executeSQLite(
    at: directory.appendingPathComponent("Dynamic.itdb"),
    sql: """
      CREATE TABLE item_stats (
        item_pid INTEGER, has_been_played INTEGER, date_played INTEGER,
        play_count_user INTEGER, play_count_recent INTEGER, bookmark_time_ms REAL,
        bookmark_time_ms_common REAL, user_rating INTEGER, user_rating_common INTEGER);
      CREATE TABLE container_ui (
        container_pid INTEGER, play_order INTEGER, is_reversed INTEGER,
        album_field_order INTEGER, repeat_mode INTEGER, shuffle_items INTEGER,
        has_been_shuffled INTEGER);
      CREATE TABLE rental_info (item_pid INTEGER);
      """)
  try executeSQLite(
    at: directory.appendingPathComponent("Locations.itdb"),
    sql: """
      CREATE TABLE base_location (id INTEGER, path TEXT);
      CREATE TABLE location (
        item_pid INTEGER, sub_id INTEGER, base_location_id INTEGER, location_type INTEGER,
        location TEXT, extension INTEGER, kind_id INTEGER, date_created INTEGER,
        file_size INTEGER, PRIMARY KEY (item_pid, sub_id));
      """)
  try executeSQLite(
    at: directory.appendingPathComponent("Extras.itdb"),
    sql: "CREATE TABLE chapter (item_pid INTEGER);")
  try executeSQLite(
    at: directory.appendingPathComponent("Genius.itdb"),
    sql: "CREATE TABLE genius_metadata (genius_id INTEGER);")
  try Data("Apple fixture CBK".utf8).write(
    to: directory.appendingPathComponent("Locations.itdb.cbk"))
}

func executeSQLite(at url: URL, sql: String) throws {
  var database: OpaquePointer?
  #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
  defer { sqlite3_close(database) }
  var message: UnsafeMutablePointer<CChar>?
  guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
    let detail = message.map { String(cString: $0) } ?? "unknown SQLite error"
    sqlite3_free(message)
    throw ITunesDBError.badHeader(detail)
  }
}

func sqliteCount(at url: URL, table: String) throws -> Int {
  Int(try sqliteInt(at: url, query: "SELECT COUNT(*) FROM \(table)"))
}

func sqliteInt(at url: URL, query: String) throws -> Int64 {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK else {
    throw ITunesDBError.badHeader("could not open test SQLite database")
  }
  defer { sqlite3_close(database) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
    throw ITunesDBError.badHeader("could not prepare test SQLite query")
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW else {
    throw ITunesDBError.badHeader("could not read test SQLite integer")
  }
  return sqlite3_column_int64(statement, 0)
}
