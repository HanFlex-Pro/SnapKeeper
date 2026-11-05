// 탐지 기준값. 값을 바꾸면 docs/DETECTION.md도 함께 고친다.
// 모두 샘플 사진으로 보정하기 전의 임시값이다.

/// 분석용 축소 이미지의 긴 변 길이(px).
const analysisMaxEdge = 1024;

/// 거의 동일: pHash 해밍 거리 상한.
const nearDuplicateMaxHamming = 2;

/// 거의 동일: 가로세로 비율 차이 상한 (비율).
const nearDuplicateMaxAspectDiff = 0.01;

/// 거의 동일: 평균 색의 채널별 차이 상한 (0~255).
const nearDuplicateMaxColorDiff = 12;

/// 거의 동일: 평균 채도 차이 상한 (0~255). 흑백본처럼 색만 뺀 사진을 구분한다.
const nearDuplicateMaxSaturationDiff = 10.0;

/// 밝기 표준편차가 이 값보다 작으면 평탄한 이미지로 보고 거의 동일 비교에서 뺀다.
const flatImageMaxGrayStd = 6.0;

/// 저화질: 총 픽셀 수가 이보다 적으면 후보. 카메라 EXIF가 있는 사진은 제외한다.
const lowResolutionMaxPixels = 500000;

/// 초점 불량: 선명도(타일별 라플라시안 분산의 최댓값)가 이보다 낮으면 후보.
const blurryMaxSharpness = 40.0;
