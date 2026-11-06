import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../core/duplicates.dart';
import '../core/image_features.dart';
import 'photo_scanner.dart';

/// 분석 알고리즘이 바뀌면 올린다. 버전이 다른 사진은 다시 분석한다.
const analysisVersion = 2; // 2: 선명도, 위치 추가 (v0.3)

/// 사진 한 장의 분석 결과. 디코딩에 실패해도 해시와 EXIF는 채운다.
class PhotoAnalysis {
  const PhotoAnalysis({
    required this.sha256,
    this.features,
    this.width,
    this.height,
    this.takenAt,
    this.camera,
    this.latitude,
    this.longitude,
    this.error,
    this.screenshotMarker = false,
  });

  final String sha256;
  final ImageFeatures? features;
  final int? width;
  final int? height;
  final DateTime? takenAt;
  final String? camera;
  final double? latitude;
  final double? longitude;
  final String? error;
  final bool screenshotMarker;
}

/// 앱 데이터 폴더의 SQLite DB. 사진 분석 결과, 보관한 사진, 고른 폴더를 저장한다.
class PhotoDatabase {
  PhotoDatabase._(this._db) {
    _db.execute('PRAGMA journal_mode = WAL');
    _migrate();
  }

  factory PhotoDatabase.open(String path) =>
      PhotoDatabase._(sqlite3.open(path));

  factory PhotoDatabase.memory() => PhotoDatabase._(sqlite3.openInMemory());

  final Database _db;

  void dispose() => _db.close();

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version < 1) {
      _db.execute('''
        CREATE TABLE photos(
          id INTEGER PRIMARY KEY,
          path TEXT NOT NULL UNIQUE,
          size_bytes INTEGER NOT NULL,
          modified_at INTEGER NOT NULL,
          sha256 TEXT,
          phash INTEGER,
          mean_rgb INTEGER,
          gray_std REAL,
          saturation REAL,
          width INTEGER,
          height INTEGER,
          taken_at INTEGER,
          camera TEXT,
          analysis_version INTEGER,
          error TEXT
        );
        CREATE INDEX photos_sha256 ON photos(sha256);
        CREATE TABLE kept_photos(
          sha256 TEXT PRIMARY KEY,
          kept_at INTEGER NOT NULL
        );
        CREATE TABLE folders(
          path TEXT PRIMARY KEY,
          bookmark TEXT,
          selected_at INTEGER NOT NULL
        );
        PRAGMA user_version = 1;
      ''');
    }
    if (version < 2) {
      // 새 열은 비어 있고, analysisVersion이 올라가 모든 사진을 다시 분석한다.
      _db.execute('''
        ALTER TABLE photos ADD COLUMN sharpness REAL;
        ALTER TABLE photos ADD COLUMN latitude REAL;
        ALTER TABLE photos ADD COLUMN longitude REAL;
        PRAGMA user_version = 2;
      ''');
    }
    if (version < 3) {
      // 캡처 표시는 카메라 정보가 없는 사진에만 있으므로, 그 사진만 다시 분석한다.
      _db.execute('''
        ALTER TABLE photos ADD COLUMN screenshot_marker INTEGER;
        UPDATE photos SET analysis_version = NULL WHERE camera IS NULL;
        PRAGMA user_version = 3;
      ''');
    }
  }

  // --- 폴더

  /// 마지막으로 고른 폴더.
  ({String path, String? bookmark})? lastFolder() {
    final rows = _db.select(
      'SELECT path, bookmark FROM folders ORDER BY selected_at DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    return (
      path: rows.first['path'] as String,
      bookmark: rows.first['bookmark'] as String?,
    );
  }

  void saveFolder(String path, String? bookmark) {
    _db.execute(
      // Windows는 시계 해상도가 낮아 연달아 저장하면 시각이 같을 수 있다. 항상 이전보다 크게 한다.
      'INSERT INTO folders(path, bookmark, selected_at) VALUES (?, ?, '
      'MAX(?, (SELECT COALESCE(MAX(selected_at), 0) + 1 FROM folders))) '
      'ON CONFLICT(path) DO UPDATE SET bookmark = excluded.bookmark, '
      'selected_at = excluded.selected_at',
      [path, bookmark, DateTime.now().microsecondsSinceEpoch],
    );
  }

  /// v0.1의 settings.json을 옮기고 지운다. 파일이 깨졌으면 그냥 지운다.
  void importLegacySettings(File file) {
    if (!file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final path = json['folderPath'] as String?;
      if (path != null && lastFolder() == null) {
        saveFolder(path, json['bookmark'] as String?);
      }
    } catch (_) {
      // 깨진 설정은 버린다. 사용자가 폴더를 다시 고르면 된다.
    }
    file.deleteSync();
  }

  // --- 사진

  /// 폴더 목록을 DB에 반영하고, 분석이 필요한 경로를 돌려준다.
  /// 새 파일과 크기·수정 시각이 바뀐 파일은 분석 결과를 지우고, 사라진 파일은 행을 지운다.
  List<String> sync(String root, List<PhotoFile> listed) {
    final existing = <String, (int, int, int?)>{
      for (final row in _db.select(
        'SELECT path, size_bytes, modified_at, analysis_version FROM photos '
        'WHERE substr(path, 1, ?) = ?',
        [_prefix(root).length, _prefix(root)],
      ))
        row['path'] as String: (
          row['size_bytes'] as int,
          row['modified_at'] as int,
          row['analysis_version'] as int?,
        ),
    };
    final pending = <String>[];
    _transaction(() {
      final insert = _db.prepare(
        'INSERT INTO photos(path, size_bytes, modified_at) VALUES (?, ?, ?)',
      );
      final reset = _db.prepare(
        'UPDATE photos SET size_bytes = ?, modified_at = ?, sha256 = NULL, '
        'phash = NULL, mean_rgb = NULL, gray_std = NULL, saturation = NULL, '
        'width = NULL, height = NULL, taken_at = NULL, camera = NULL, '
        'sharpness = NULL, latitude = NULL, longitude = NULL, '
        'screenshot_marker = NULL, analysis_version = NULL, error = NULL '
        'WHERE path = ?',
      );
      for (final file in listed) {
        final modified = file.modified.millisecondsSinceEpoch;
        final old = existing.remove(file.path);
        if (old == null) {
          insert.execute([file.path, file.size, modified]);
          pending.add(file.path);
        } else if (old.$1 != file.size || old.$2 != modified) {
          reset.execute([file.size, modified, file.path]);
          pending.add(file.path);
        } else if (old.$3 != analysisVersion) {
          pending.add(file.path);
        }
      }
      final delete = _db.prepare('DELETE FROM photos WHERE path = ?');
      for (final gone in existing.keys) {
        delete.execute([gone]);
      }
      insert.close();
      reset.close();
      delete.close();
    });
    return pending;
  }

  void saveAnalyses(Map<String, PhotoAnalysis> results) {
    _transaction(() {
      final update = _db.prepare(
        'UPDATE photos SET sha256 = ?, phash = ?, mean_rgb = ?, gray_std = ?, '
        'saturation = ?, width = ?, height = ?, taken_at = ?, camera = ?, '
        'sharpness = ?, latitude = ?, longitude = ?, screenshot_marker = ?, '
        'analysis_version = ?, error = ? WHERE path = ?',
      );
      for (final MapEntry(key: path, value: a) in results.entries) {
        update.execute([
          a.sha256,
          a.features?.phash,
          a.features?.meanRgb,
          a.features?.grayStd,
          a.features?.saturation,
          a.width,
          a.height,
          a.takenAt?.millisecondsSinceEpoch,
          a.camera,
          a.features?.sharpness,
          a.latitude,
          a.longitude,
          a.screenshotMarker ? 1 : 0,
          analysisVersion,
          a.error,
          path,
        ]);
      }
      update.close();
    });
  }

  /// [root] 아래의 모든 사진.
  List<PhotoRecord> records(String root) => [
    for (final row in _db.select(
      'SELECT * FROM photos WHERE substr(path, 1, ?) = ?',
      [_prefix(root).length, _prefix(root)],
    ))
      PhotoRecord(
        path: row['path'] as String,
        size: row['size_bytes'] as int,
        modified: DateTime.fromMillisecondsSinceEpoch(
          row['modified_at'] as int,
        ),
        sha256: row['sha256'] as String?,
        phash: row['phash'] as int?,
        meanRgb: row['mean_rgb'] as int?,
        grayStd: _real(row['gray_std']),
        saturation: _real(row['saturation']),
        width: row['width'] as int?,
        height: row['height'] as int?,
        takenAt: switch (row['taken_at']) {
          final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
          _ => null,
        },
        camera: row['camera'] as String?,
        sharpness: _real(row['sharpness']),
        latitude: _real(row['latitude']),
        longitude: _real(row['longitude']),
        error: row['error'] as String?,
        screenshotMarker: switch (row['screenshot_marker']) {
          final int v => v == 1,
          _ => null,
        },
      ),
  ];

  /// 휴지통으로 옮긴 사진을 지운다.
  void removePhoto(String path) =>
      _db.execute('DELETE FROM photos WHERE path = ?', [path]);

  // --- 보관

  void keep(Iterable<String> sha256s) {
    _transaction(() {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final sha in sha256s) {
        _db.execute(
          'INSERT OR IGNORE INTO kept_photos(sha256, kept_at) VALUES (?, ?)',
          [sha, now],
        );
      }
    });
  }

  Set<String> keptSha256() => {
    for (final row in _db.select('SELECT sha256 FROM kept_photos'))
      row['sha256'] as String,
  };

  // --- 내부

  /// SQLite는 소수점 없는 실수를 정수로 돌려줄 수 있다.
  static double? _real(Object? v) => (v as num?)?.toDouble();

  /// 폴더 이름이 같은 다른 폴더(`/사진` 과 `/사진2`)가 섞이지 않도록 구분자까지 붙인다.
  static String _prefix(String root) => root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';

  void _transaction(void Function() body) {
    _db.execute('BEGIN');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }
}
