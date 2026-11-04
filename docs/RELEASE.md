# 릴리즈 절차

버전은 SemVer(`v0.2.0`)를 따릅니다. `pubspec.yaml`의 `version`은 `이름+빌드번호` 형식이며, 빌드 번호는 릴리즈할 때마다 1씩 올립니다.

## 1. 준비 (`chore/release-X.Y.Z` 브랜치)
- [ ] 해당 Milestone의 Issue가 모두 닫혔는지 확인
- [ ] 사용자가 실제 사진 폴더 복사본으로 앱을 확인
- [ ] `pubspec.yaml`의 `version` 올리기
- [ ] `CHANGELOG.md`에 추가, 알려진 제한 정리
- [ ] PR 생성 → Windows CI 통과 + 로컬 macOS 확인 → 사용자 승인 후 Squash merge

## 2. 빌드와 배포 (`main`에서)
- [ ] `main`의 Windows CI 통과 확인
- [ ] 로컬에서 `flutter test`, `flutter build macos --release`
- [ ] 압축: `ditto -c -k --keepParent build/macos/Build/Products/Release/snapkeeper.app SnapKeeper-X.Y.Z-macos.zip`
- [ ] 태그: `git tag -a vX.Y.Z -m "vX.Y.Z"` → `git push origin vX.Y.Z`
- [ ] GitHub 릴리즈: `gh release create vX.Y.Z SnapKeeper-X.Y.Z-macos.zip --notes-file <CHANGELOG의 해당 절>`
- [ ] Milestone 닫기

## 아직 하지 않는 것
- **코드 서명과 공증:** 개인 사용 단계라 생략합니다. 공개 배포를 결정하면(v1.0 전) Apple Developer 계정과 함께 추가합니다.
- **Windows 설치 파일:** v0.5에서 추가합니다.
