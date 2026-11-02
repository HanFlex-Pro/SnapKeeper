# SnapKeeper

사진을 기기 안에서 분석해 동일 이미지와 소장 가치가 낮은 사진을 찾아 주는 Flutter 앱입니다.

문서: [PRD](docs/PRD.md) · [아키텍처](docs/ARCHITECTURE.md) · [탐지 기준](docs/DETECTION.md) · [ADR](docs/adr/)

## 명령어

```sh
flutter analyze
flutter test
dart format .
flutter run -d macos
```

## 안전 규칙 (예외 없음)

- 사진 파일을 영구 삭제하지 않습니다. OS 휴지통으로만 옮기고, 실패하면 파일을 그대로 둡니다.
- 사용자 확인 없이 어떤 사진 파일도 옮기거나 수정하지 않습니다.
- 그룹의 모든 사진을 삭제하려 하면 경고합니다.
- 사진과 메타데이터를 외부로 전송하지 않습니다.
- 삭제 관련 코드에는 자동 테스트가 반드시 있어야 합니다.
- 테스트는 합성 이미지와 임시 폴더만 사용합니다. 실제 사진은 사용자가 지정한 복사본 폴더에서만 다룹니다.

## 코드 규칙

- `lib/core/`는 순수 Dart로 작성하고 Flutter, 파일 시스템, 다른 `lib/` 폴더에 의존하지 않습니다.
- OS별 코드는 `lib/platform/`에 모읍니다.
- 탐지 기준값은 `lib/core/thresholds.dart`에만 두고, 바꾸면 `docs/DETECTION.md`도 함께 고칩니다.
- 분석 알고리즘을 바꾸면 `analysis_version`을 올립니다.
- 패키지를 추가하기 전에 Flutter와 Dart 기본 기능으로 해결되는지 확인합니다.
- 버그를 고칠 때는 재현 테스트를 함께 추가합니다.

## Git 규칙

- GitHub Flow를 따릅니다. `main`에 직접 커밋하지 않습니다.
- 브랜치: `feat/`, `fix/`, `docs/`, `refactor/`, `chore/` + 설명. Issue가 있으면 번호 포함. 예: `feat/12-duplicate-scan`
- 커밋: Conventional Commits. 예: `feat(scan): 파일 해시 기반 중복 탐지 추가`
- PR: 한 가지 목적만 담고 관련 Issue를 연결합니다.
- 병합: Squash merge. CI 통과와 사용자 승인이 모두 필요하며, Claude가 임의로 병합하지 않습니다.
- 릴리즈: SemVer 태그(`v0.2.0`)와 `CHANGELOG.md` 갱신.

## 작업 방식

- Issue 확인 → 구현 → 테스트 실행 → PR 생성 → 사용자 승인 순서로 진행합니다.
- 실제로 실행한 테스트와 빌드 결과만 보고합니다.
- 범위를 벗어난 수정은 하지 않고 별도 Issue로 남깁니다.
- 되돌리기 어려운 결정은 `docs/adr/`에 짧게 기록합니다.
