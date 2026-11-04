# SnapKeeper 아키텍처

상태: 확정 · 최종 수정: 2026-11-03

요구사항은 [PRD](PRD.md), 탐지 알고리즘은 [DETECTION](DETECTION.md)을 봅니다.

## 1. 구조

Flutter 앱 하나로 구성하며 서버는 없습니다.

```text
lib/
  main.dart
  core/       순수 Dart. 해시, 선명도, 그룹화, 기준값. Flutter와 파일 시스템에 의존하지 않음
  data/       SQLite(drift), 폴더 스캔, 분석 파이프라인
  platform/   OS별 코드. 휴지통 이동, 이미지 디코딩
  ui/         화면
test/         core와 data 단위 테스트
tool/         정확도 평가 등 개발용 스크립트
```

의존 방향은 `ui → data → core`이고, `data`는 OS 기능이 필요할 때 `platform`을 호출합니다. `core`는 다른 폴더를 가져오지 않습니다.

모바일 보관함을 지원하는 v0.6 전까지는 사진 출처를 추상화하지 않습니다. 구현이 폴더 하나뿐이기 때문입니다.

## 2. 스캔 흐름

```text
폴더 선택
  → 1. 목록 수집: 지원 확장자만, 심볼릭 링크는 따라가지 않음
  → 2. 변경 확인: 경로, 크기, 수정 시각이 DB와 같으면 건너뜀
  → 3. 파일 읽기: SHA-256, EXIF
  → 4. 디코딩: 긴 변 1024px로 축소한 RGBA
  → 5. 분석: pHash, 선명도 (Isolate)
  → 6. DB 저장: 묶음 단위로 저장해 중단 후 이어서 진행
  → 7. 후보 계산: 저장된 값과 기준값으로 분류와 그룹 계산
```

- 후보는 DB에 저장하지 않고 조회할 때 계산합니다. 기준값을 바꿔도 다시 스캔할 필요가 없습니다.
- 알고리즘이 바뀌면 `analysis_version`을 올려 해당 사진만 다시 분석합니다.
- 분석할 수 없는 파일은 오류를 기록하고 건너뛰며, 삭제 후보로 올리지 않습니다.

### 디코딩

`image` 패키지의 지원 형식 목록에는 HEIC가 없어 Flutter의 `dart:ui` 코덱으로 디코딩합니다. `core`는 디코딩된 픽셀만 입력받습니다.

- `dart:ui` 디코딩은 백그라운드 Isolate에서 동작하지 않습니다. 디코딩은 메인 Isolate에서 비동기로 호출하고, 해시와 분석만 Isolate에서 실행합니다.
- Windows에서는 HEIC를 디코딩할 수 없어 "분석 불가"로 기록하고 건너뜁니다.

### 스캔 중 시스템 제약

macOS에서는 스캔하는 동안 `ProcessInfo.beginActivity`로 App Nap을 막습니다. 막지 않으면 앱이 가려졌을 때 스캔이 크게 느려질 수 있습니다.

## 3. 데이터베이스

```text
photos
  id               INTEGER PRIMARY KEY
  path             TEXT UNIQUE NOT NULL
  size_bytes       INTEGER NOT NULL
  modified_at      INTEGER NOT NULL
  sha256           TEXT
  phash            INTEGER        -- 64비트
  width, height    INTEGER
  taken_at         INTEGER
  camera_make      TEXT
  camera_model     TEXT
  latitude         REAL
  longitude        REAL
  sharpness        REAL
  analysis_version INTEGER
  error            TEXT

  INDEX (sha256), INDEX (taken_at)

kept_photos
  sha256           TEXT PRIMARY KEY
  kept_at          INTEGER NOT NULL

folders
  path             TEXT PRIMARY KEY
  bookmark         BLOB           -- macOS 보안 북마크
```

- "보관" 표시는 경로가 아니라 SHA-256에 저장합니다. 파일을 옮기거나 이름을 바꿔도 유지됩니다.
- macOS 샌드박스는 재실행하면 폴더 접근 권한을 회수합니다. 폴더를 고를 때 보안 북마크를 저장하고, 실행할 때 복원해 접근합니다.
- DB는 앱 데이터 폴더에 두며 사진 파일 옆에 아무것도 만들지 않습니다.

## 4. 삭제 흐름

```text
사용자 선택 → 확인 창(장수, 확보 용량) → 파일별로:
  1. 크기와 수정 시각이 DB와 같은지 다시 확인. 다르면 건너뜀
  2. OS 휴지통으로 이동. 실패하면 파일을 그대로 두고 사유 기록
  3. 성공한 파일만 DB에서 제거
→ 결과 요약(성공, 건너뜀, 실패)
```

- 영구 삭제로 넘어가는 경로를 두지 않습니다. 휴지통 이동이 실패하면 그 파일은 실패로 끝납니다.
- 그룹 전체를 선택하면 확인 창에서 별도로 경고합니다.
- 이동 대상은 사용자가 고른 경로 목록뿐이며, 탐지 코드는 파일을 옮기는 기능을 호출하지 않습니다.

## 5. M0 기술 검증

| # | 검증 항목 | 통과 기준 |
|---|---|---|
| 1 | `dart:ui`로 JPEG, PNG, HEIC, WebP를 축소 디코딩하고 EXIF 회전이 적용되는지 (macOS, Windows) | macOS 전 형식 통과. Windows HEIC 결과에 따라 PRD 지원 형식 확정 |
| 2 | 사진 1만 장 스캔 시간과 최대 메모리 | 10만 장 스캔이 하룻밤 안에 끝나는 속도, 메모리가 장수에 비례해 늘지 않음 |
| 3 | 휴지통 이동: macOS `NSFileManager.trashItem`, Windows Shell API | 휴지통에서 복원 가능. 휴지통이 없는 위치에서는 영구 삭제 없이 실패 |
| 4 | macOS 샌드박스에서 사용자가 고른 폴더 읽기와 휴지통 이동, 재실행 후 접근 유지 | 동작 확인. 재실행 후 접근에 보안 북마크가 필요한지 판단 |

Windows 3번은 파일을 영구 삭제할 위험이 있으므로 임시 파일로만 시험합니다.

### 검증 결과 (2026-11-03)

환경: macOS는 Apple M2 8코어, 메모리 16GB. Windows는 GitHub Actions `windows-latest`.

| 항목 | macOS | Windows |
|---|---|---|
| JPEG, PNG, WebP 디코딩 | 통과 (WebP는 무손실만 시험) | 통과 (WebP는 무손실만 시험) |
| HEIC 디코딩 | 통과 | **실패** (`Invalid image data`) |
| EXIF 회전 | JPEG, HEIC 통과 | JPEG 통과 |
| 백그라운드 Isolate 디코딩 | 불가 | 불가 |
| 스캔 속도 | 파일당 37.6ms, 1만 장 6분 16초 | JPEG만 파일당 약 200ms (500장) |
| 최대 메모리 | 695MB, 장수에 비례해 늘지 않음 | 428MB (500장) |
| 휴지통 이동과 복원 | 통과 | 통과 |
| 없는 파일 | 오류 반환 | 오류 반환 |
| 휴지통을 쓸 수 없는 위치 | 읽기 전용 볼륨에서 오류, 파일 유지 | **미검증** |
| 샌드박스 폴더 접근 | 통과. 재실행 후에는 보안 북마크가 있어야 접근 가능 | 해당 없음 |

- **App Nap:** 막지 않은 측정에서는 1만 장에 27분 17초가 걸렸고, 속도가 파일당 약 40ms에서 240ms 사이로 흔들렸습니다. 조건을 엄밀히 통제한 비교는 아니지만, 막은 뒤에는 처음부터 끝까지 일정했습니다.
- **측정의 한계:** 합성 이미지 2개(12MP)를 반복해 읽었기 때문에 디스크 읽기가 거의 반영되지 않았고, DB 저장도 포함하지 않았습니다. HDD나 네트워크 드라이브에서는 더 느립니다.
- **10만 장 추정:** macOS에서 약 1시간으로, 하룻밤 기준을 충족합니다.
- **Windows 속도:** CI 러너 기준이라 실제 PC 성능과 다릅니다.
- **샌드박스:** 사용자가 고른 폴더(2,990개 항목)는 선택 직후 읽기와 휴지통 이동이 됐습니다. 재실행하면 북마크 없이는 `PathAccessException`이 났고, 보안 북마크로 복원하면 읽기와 휴지통 이동이 모두 됐습니다.
- **Windows 휴지통:** 휴지통을 쓸 수 없는 위치에서 영구 삭제되지 않는지는 v0.5에서 실제 PC로 확인합니다. 확인 전에는 Windows 삭제 기능을 릴리즈하지 않습니다.

## 6. OS별 차이

| 항목 | macOS | Windows | iOS (v0.6) | Android (v0.7) |
|---|---|---|---|---|
| 사진 접근 | 폴더 선택 | 폴더 선택 | 보관함 권한 | 보관함 권한 |
| 삭제 | 휴지통 | 휴지통 | 최근 삭제된 항목, OS 확인 창 | 휴지통 요청, OS 확인 창 |
| 캡처 판별 | 규칙 | 규칙 | OS 메타데이터 | 경로, 규칙 |

모바일 항목은 해당 버전 설계에서 확정합니다.

## 7. 테스트

- `core`: 합성 이미지로 단위 테스트
- `data`: 임시 폴더와 메모리 DB로 스캔, 재스캔, 중단 후 재개 테스트
- 삭제: 선택한 파일만 이동, 변경된 파일 건너뜀, 실패 시 파일과 DB 유지 테스트
- CI: macOS와 Windows에서 `flutter analyze`, `flutter test`, 릴리즈 빌드
