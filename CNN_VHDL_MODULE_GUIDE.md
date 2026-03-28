# CNN VHDL Module Guide

VHDP(VHDPlus) -> 표준 VHDL 변환 문서.
원본: `OnSemi_CNN_Ultra/Libraries/CNN/` (Leon Beier, Protop Solutions UG, 2020)
타겟: Zybo Z7-20 (xc7z020clg400-1), Vivado 2023.2

---

## 전체 아키텍처

```
iStream (448x448 RGB, New_Pixel clock)
    |
    +-> [Grayscale 변환]
    |   Gray = (77*R + 150*G + 29*B) >> 8  (BT.601)
    |
    +-> [Crop] Column_Offset=80, 유효 영역 클리핑
    |
    v
[max_pooling_pre] 448x448 -> 28x28 (16:1 다운스케일)
    |
    v
[rgb_to_cnn] rgb_stream -> CNN_Stream_T (8bit -> 10bit)
    |
    v
[CNN_Convolution 1] 28x28x1 -> 28x28x4 (3x3, 4필터, same, ReLU)
    |  Expand_Cycles=240, Calc_Cycles=4, Filter_Cycles=4
    v
[CNN_Pooling 1] 28x28x4 -> 14x14x4 (2x2, stride=2)
    |
    v
[CNN_Convolution 2] 14x14x4 -> 14x14x6 (3x3, 6필터, same, ReLU)
    |  Expand_Cycles=960, Input_Cycles=4, Calc_Cycles=6
    v
[CNN_Pooling 2] 14x14x6 -> 7x7x6 (2x2, stride=2)
    |
    v
[CNN_Convolution 3] 7x7x6 -> 7x7x8 (3x3, 8필터, same, ReLU)
    |  Expand_Cycles=3840, Input_Cycles=6, Calc_Cycles=8
    v
[CNN_Pooling 3] 7x7x8 -> 3x3x8 (2x2, stride=2)
    |  Filter_Delay=10
    v
[Flatten] 3D -> 1D 인덱스: iCycle = (Row*3 + Column)*8 + Filter
    |
    v
[NN_Layer] 72입력 -> 10출력 (Fully Connected, ReLU)
    |  Calc_Cycles_In=576, Out_Cycles=10
    v
[Argmax] 10개 출력 중 최대값 선택
    |
    v
Prediction (0~9) + Probability (0~1023)
```

---

## 합성 결과 (Zybo Z7-20)

| 리소스 | 사용 | 가용 | 사용률 |
|--------|------|------|--------|
| Slice LUTs | 1,789 | 53,200 | 3.36% |
| Slice Registers | 2,395 | 106,400 | 2.25% |
| Block RAM | 3 tiles | 140 tiles | 2.14% |
| DSP48E1 | 4 | 220 | 1.82% |

Pcam 파이프라인과 함께 사용해도 리소스 충분.

---

## 컴파일 순서

Vivado에서 소스 추가 시 아래 순서를 따를 것.

1. `image_data_pkg.vhd`
2. `cnn_config_pkg.vhd`
3. `cnn_data_pkg.vhd`
4. `cnn_row_expander.vhd`
5. `cnn_row_buffer.vhd`
6. `cnn_convolution.vhd`
7. `cnn_pooling.vhd`
8. `nn_layer.vhd`
9. `max_pooling_pre.vhd`
10. `rgb_to_cnn.vhd`
11. `cnn_top.vhd`

---

## 모듈별 상세 설명

---

### 1. image_data_pkg.vhd

- **원본**: `OnSemi_Image_Data_USB.vhdp`
- **역할**: 카메라 데이터 스트림 기본 타입 정의

#### 핵심 타입

```vhdl
type rgb_data is record
    R : std_logic_vector(7 downto 0);
    G : std_logic_vector(7 downto 0);
    B : std_logic_vector(7 downto 0);
end record;

type rgb_stream is record
    R, G, B   : std_logic_vector(7 downto 0);  -- 픽셀 색상
    Column    : natural range 0 to 645;          -- X좌표
    Row       : natural range 0 to 482;          -- Y좌표
    New_Pixel : std_logic;                       -- 픽셀 클럭
end record;
```

`rgb_stream.New_Pixel`이 이 시스템의 **픽셀 클럭**. 매 rising edge에 새 픽셀 유효.

#### 상수

| 상수 | 값 | 의미 |
|------|----|------|
| Image_Width | 646 | 카메라 출력 폭 (유효 640 + 여백) |
| Image_Height | 483 | 카메라 출력 높이 |
| HDMI_Width/Height | 640/480 | HDMI 출력 해상도 |

---

### 2. cnn_config_pkg.vhd

- **원본**: `CNN_Config.vhdp`
- **역할**: CNN 전역 데이터 타입, 비트폭, 활성화 함수 정의

#### 고정소수점 체계

```
CNN_Value_Resolution  = 10bit  -> 값 범위: 0~1023 (활성화 출력)
CNN_Weight_Resolution = 8bit   -> 값 범위: -127~+127 (2^7 = 1.0)
CNN_Value_Negative    = 0      -> ReLU 사용시 음수 없음
```

#### 핵심 타입

| 타입 | 설명 |
|------|------|
| `CNN_Value_T` | natural 0~1023 (10bit 양수) |
| `CNN_Values_T` | CNN_Value_T의 1D 배열 |
| `CNN_Weight_T` | integer -127~+127 (8bit 부호) |
| `CNN_Weights_T` | 2D 가중치 배열 [필터][입력] |
| `CNN_Stream_T` | Column + Row + Filter + Data_Valid + Data_CLK |
| `Activation_T` | relu, linear, leaky_relu, step_func, sign_func |
| `Padding_T` | valid, same |

#### CNN_Stream_T 스트리밍 프로토콜

```
Data_CLK   __/-\__/-\__/-\__    <- 데이터 클럭
Data_Valid  ____/------\______   <- '1' 구간에서만 데이터 유효
Column      --0--|--1--|--2--    <- 현재 픽셀 X좌표
Row         --0--|--0--|--0--    <- 현재 픽셀 Y좌표
Filter      --0--|--0--|--0--    <- 현재 필터/채널 번호
```

CNN 내부 모든 레이어가 이 프로토콜로 연결됨. `rgb_stream.New_Pixel`에서 `CNN_Stream_T.Data_CLK`로 전환.

#### 활성화 함수

| 함수 | 동작 | 비고 |
|------|------|------|
| `relu_f(i, max)` | `max(0, min(i, 1023))` | integer/signed 오버로드 |
| `linear_f(i, max)` | `clamp(i, -max, max)` | |
| `leaky_relu_f(i, max, bits)` | 양수: relu, 음수: `i * 0.1` | leaky_relu_mult = 12 |
| `step_f(i)` | `i>=0 -> 128, else 0` | |
| `sign_f(i)` | `i>0 -> 128, i<0 -> -128, else 0` | |

이 프로젝트에서는 **relu만 사용** (전 레이어).

---

### 3. cnn_data_pkg.vhd

- **원본**: `Data_Package.vhdp`
- **역할**: TensorFlow 학습 가중치 + 바이어스를 ROM 상수로 저장

#### 네트워크 구조

```
Layer 1: 28x28x1 -> Conv 3x3, 4 filters, same, stride=1 -> 28x28x4
  가중치: 4 x 10 = 40개 (3x3=9 kernel + 1 bias)

Pooling 1: 28x28x4 -> MaxPool 2x2, stride=2 -> 14x14x4

Layer 2: 14x14x4 -> Conv 3x3, 6 filters, same, stride=1 -> 14x14x6
  가중치: 6 x 37 = 222개 (3x3x4=36 kernel + 1 bias)

Pooling 2: 14x14x6 -> MaxPool 2x2, stride=2 -> 7x7x6

Layer 3: 7x7x6 -> Conv 3x3, 8 filters, same, stride=1 -> 7x7x8
  가중치: 8 x 55 = 440개 (3x3x6=54 kernel + 1 bias)

Pooling 3: 7x7x8 -> MaxPool 2x2, stride=2 -> 3x3x8

Flatten: 3x3x8 = 72

NN_Layer_1: 72 -> 10 (digit 0~9)
  가중치: 10 x 73 = 730개 (72 input + 1 bias)

총 가중치: 1,438개 (8-bit 고정소수점)
```

#### Offset 파라미터 (고정소수점 스케일링)

| 레이어 | Out_Offset | 의미 |
|--------|------------|------|
| Layer 1 | 3 | 출력을 2^3=8로 나눔 |
| Layer 2 | 3 | 출력을 2^3=8로 나눔 |
| Layer 3 | 5 | 출력을 2^5=32로 나눔 |
| NN_Layer_1 | 6 | 출력을 2^6=64로 나눔 |

레이어가 깊어질수록 Offset 증가 -> 누적 곱셈 결과를 10bit 범위(0~1023)로 스케일 조정.

---

### 4. cnn_row_expander.vhd

- **원본**: `CNN_Row_Expander.vhdp`
- **역할**: 입력 데이터 사이에 빈 사이클 삽입 -> Convolution 계산 시간 확보

#### 타이밍 개념

```
입력:  -_-_-_-_________  (데이터가 빠르게 연속 도착)
출력:  -___-___-___-___  (데이터 사이에 빈 사이클 삽입)
```

#### 내부 구조

```
iData -> [falling edge] -> Buffer_RAM (한 행 저장)
                                |
         [rising edge]  <- RAM_Data_Out <- [falling edge] 읽기
                |
         Delay_Cnt 카운터로 출력 간격 조절
                |
                v
         oData (확장된 타이밍)
```

- `Buffer_RAM`: 한 행 분량 저장 (Input_Columns x Input_Cycles 깊이)
- `Delay_Cnt`: 0이 되면 다음 데이터 출력, `Output_Cycles-1`까지 카운트
- RAM 쓰기는 falling edge, 읽기도 falling edge (쓰기/읽기 충돌 방지)

#### 사용 위치

| 레이어 | Expand_Cycles | 의미 |
|--------|---------------|------|
| Conv1 | 240 | 28 pixel -> 240 cycles/pixel |
| Conv2 | 960 | 14 pixel -> 960 cycles/pixel |
| Conv3 | 3840 | 7 pixel -> 3840 cycles/pixel |

---

### 5. cnn_row_buffer.vhd

- **원본**: `CNN_Row_Buffer.vhdp`
- **역할**: 여러 행 버퍼링 -> Filter_Rows x Filter_Columns 매트릭스 출력

#### 동작 개념

```
입력: 픽셀 스트림 (한 번에 1개)

Buffer_RAM (순환 버퍼):
  Row 0: [p00, p01, p02, ... p27]
  Row 1: [p10, p11, p12, ... p17]
  Row 2: [p20, p21, p22, ... p27]  <- 현재 쓰기 행

출력: 3x3 윈도우 요소를 순차적으로:
  [p00, p01, p02, p10, p11, p12, p20, p21, p22]
  + Row/Column/Input 인덱스
```

#### 핵심 로직

1. **입력부**: `iRow_RAM`으로 현재 쓸 행 추적 (순환: 0->1->2->0->...)
2. **출력부**: 4중 카운터로 매트릭스 순회
   - `Row_Cntr`: -1 ~ +1 (3x3 기준)
   - `Column_Cntr`: -1 ~ +1
   - `Value_Cntr`: 0 ~ Value_Cycles-1 (다중 채널)
   - `Calc_Cntr`: 0 ~ Calc_Cycles-1 (계산 사이클 간 대기)
3. **Padding 처리**:
   - `valid`: 가장자리 제외, Column/Row를 Filter/2만큼 보정
   - `same`: 가장자리 포함, 범위 밖 데이터는 0으로 패딩

#### 포트

| 포트 | 방향 | 설명 |
|------|------|------|
| iStream/iData | in | 입력 스트림 |
| oStream/oData | out | 매트릭스 요소 출력 |
| oRow | buffer | 현재 매트릭스 내 행 (0~Filter_Rows-1) |
| oColumn | buffer | 현재 매트릭스 내 열 (0~Filter_Columns-1) |
| oInput | buffer | 현재 Value_Cycle 인덱스 |

---

### 6. cnn_convolution.vhd (가장 복잡한 모듈)

- **원본**: `CNN_Convolution.vhdp`
- **역할**: 가중치 x 입력 누적 -> 바이어스 -> 활성화 -> 출력

#### 아키텍처 블록도

```
iStream/iData
    |
    v
[Row Expander] <-- Expand=true일 때 (기본)
    |
    v
[Row Buffer] -> Matrix_Data (3x3 윈도우 요소)
    |
    v
[ROM] -> Weights_Buf_Var (현재 필터의 가중치)
    |
    v
[MAC Engine] -> sum(o) += iData(i) * Weight(o,i)
    |              (다중 사이클에 걸쳐 누적)
    v
[SUM_RAM] <-- Calc_Cycles > 1일 때 필터별 부분합 저장
    |
    v
[Bias + Activation] -> ReLU(sum + bias)
    |
    v
[OUT_RAM] -> 활성화 결과 저장
    |
    v
oStream/oData <-- Filter_Cycles에 걸쳐 순차 출력
```

#### 사이클 분할 (리소스 절약 핵심)

```
예: Layer 1 (Filters=4, Calc_Cycles=4)
  -> 4필터를 1필터씩 4사이클에 걸쳐 계산
  -> DSP 1개로 4필터 처리 (시간 증가, 자원 감소)

Filter_Cycles=4:
  -> 4필터 결과를 1개씩 4사이클에 걸쳐 출력
  -> 출력 버스 폭 축소
```

#### MAC 연산 수식

```vhdl
sum(o) := sum(o) + shift_right(
    to_signed(
        iData(i) * Weights_Buf_Var(o, i) + 2**(Weight_Res - Offset - 2),
        Value_Res + Weight_Res
    ),
    Weight_Res - Offset - 1
);
```

- `iData(i)`: 10bit 값 (0~1023)
- `Weight(o,i)`: 8bit 부호 (-127~+127)
- `+ 2^(Weight_Res-Offset-2)`: 반올림 바이어스
- `>> (Weight_Res-Offset-1)`: 고정소수점 스케일 정규화

#### Init_ROM 함수

가중치 2D 배열을 `std_logic_vector` ROM으로 패킹:

```
ROM[element_idx] = {Weight[f0,s0], Weight[f1,s0], Weight[f0,s1], ...}
```

합성 시 BRAM 또는 LUT ROM으로 매핑.

#### 제네릭 파라미터

| 파라미터 | 설명 |
|----------|------|
| Input_Columns/Rows | 입력 이미지 크기 |
| Input_Values | 입력 채널 수 (이전 레이어 필터 수) |
| Filter_Columns/Rows | 커널 크기 (3x3) |
| Filters | 출력 필터 수 |
| Strides | 스트라이드 |
| Activation | 활성화 함수 종류 |
| Padding | valid 또는 same |
| Calc_Cycles | 필터 계산 분할 수 (리소스 vs 속도) |
| Filter_Cycles | 출력 분할 수 |
| Expand_Cycles | Row Expander 확장 비율 |
| Offset_In/Out/Offset | 고정소수점 스케일링 |
| Weights | 가중치 상수 배열 |

---

### 7. cnn_pooling.vhd

- **원본**: `CNN_Pooling.vhdp`
- **역할**: Filter x Filter 윈도우에서 최대값을 찾아 다운샘플링

#### 동작

```
입력: 28x28x4 (Pooling 1 기준)
윈도우: 2x2, stride=2
출력: 14x14x4

각 2x2 블록:
  [3, 7]
  [2, 5]  -> max = 7
```

#### 구조 (Convolution과 유사한 패턴)

```
[Row Expander] -> [Row Buffer] -> Matrix_Data
    |
    v
[MAX 비교] -> max(현재값, 이전 max)
    |
    v
[MAX_RAM] <-- Value_Cycles > 1일 때 부분 max 저장
    |
    v
[OUT_RAM] -> 최종 max 저장
    |
    v
oStream/oData
```

#### Convolution과의 차이

| | Convolution | Pooling |
|---|---|---|
| 연산 | MAC (곱셈-누적) | MAX (비교) |
| 가중치 | 필요 (ROM) | 불필요 |
| DSP 사용 | O | X |
| SUM_RAM | 부분합 저장 | - |
| MAX_RAM | - | 부분 max 저장 |

#### 핵심 비교 로직

```vhdl
if (Matrix_Row = 0 and Matrix_Column = 0) or MAX_ram_v > max_v(in_offset) then
    max_v(in_offset) := to_signed(MAX_ram_v, CNN_Value_Resolution+1);
end if;
```

- 윈도우 첫 요소 (0,0): 무조건 현재값으로 초기화
- 이후: 현재값 > 이전 max이면 교체

---

### 8. nn_layer.vhd

- **원본**: `NN_Layer.vhdp`
- **역할**: Fully Connected 레이어 (모든 입력 x 모든 가중치 -> 바이어스 -> 활성화)

#### Convolution과의 차이

| | Convolution | NN_Layer |
|---|---|---|
| 입력 | 3x3 윈도우 (로컬 연결) | 전체 72개 (글로벌 연결) |
| Row Buffer | 필요 | 불필요 |
| 입력 인덱스 | Column/Row/Filter | `iCycle` (평탄화된 1D 인덱스) |
| 출력 인덱스 | Column/Row/Filter | `oCycle` (출력 뉴런 번호) |

#### 이 프로젝트에서의 파라미터

```
Inputs          = 72   (3x3x8 flatten)
Outputs         = 10   (digit 0~9)
Calc_Cycles_In  = 576  (매 프레임 전체 입력 사이클)
Out_Cycles      = 10   (10개 출력을 1개씩 순차 계산)
Calc_Cycles_Out = 10   (10개 결과를 1개씩 순차 출력)
```

#### 내부 흐름

```
iData(0) + iCycle 수신 (Data_Valid='1')
    |
    v
ROM에서 Weight(Out_Offset..+Calc_Outputs, iCycle) 로드
    |
    v
sum(o) += iData(0) * Weight(o, i)  (72입력 순차 누적)
    |
    v
SUM_RAM에 부분합 저장 (Out_Cycles > 1)
    |
    v
마지막 입력 도착 시 -> Bias + ReLU -> OUT_RAM
    |
    v
oCycle=0..9 순차 출력
```

---

### 9. max_pooling_pre.vhd

- **원본**: `MAX_Pooling.vhdp`
- **역할**: 카메라 원본 영상(448x448)을 CNN 입력(28x28)으로 다운스케일

#### CNN 내부 cnn_pooling과의 차이

| | max_pooling_pre | cnn_pooling |
|---|---|---|
| 데이터 타입 | `rgb_stream` (8bit R/G/B) | `CNN_Stream_T` (10bit) |
| 클럭 | `New_Pixel` (픽셀 클럭) | `Data_CLK` (내부 클럭) |
| 필터 크기 | 16x16 (448/28) | 2x2 |
| Row Buffer | 자체 1행 RAM | cnn_row_buffer 모듈 |

#### 동작

```
448x448 -> 16x16 블록마다 max -> 28x28

열 방향: max_Col_Buf에 16개 열의 max 누적
행 방향: Buffer_RAM에 중간 행 max 저장
         16번째 행에서 최종 출력
```

---

### 10. rgb_to_cnn.vhd

- **원본**: `RGB_TO_CNN.vhdp`
- **역할**: `rgb_stream` -> `CNN_Stream_T` + `CNN_Values_T` 변환

#### 변환 매핑

```
rgb_stream.New_Pixel  ->  CNN_Stream_T.Data_CLK
rgb_stream.Column     ->  CNN_Stream_T.Column
rgb_stream.Row        ->  CNN_Stream_T.Row
rgb_stream.R (8bit)   ->  CNN_Values_T(0) (10bit, to_integer(unsigned(R)))
```

#### Data_Valid 생성

```vhdl
if iStream.Column /= Col_Reg then  -- 열 번호 변경 감지
    Data_Valid <= '1';               -- 새 데이터 유효
else
    Data_Valid <= '0';               -- 중복 무시
end if;
```

1 클럭 파이프라인 지연 있음 (`oStream_Buf` -> `oStream`).

---

### 11. cnn_top.vhd (최상위 모듈)

- **원본**: `CNN.vhdp`
- **역할**: 전처리 + CNN 3-layer + FC + Argmax 전체 파이프라인

#### 포트

| 포트 | 방향 | 타입 | 설명 |
|------|------|------|------|
| iStream | in | rgb_stream | 448x448 RGB 입력 (New_Pixel 클럭) |
| Prediction | out | natural 0~9 | 인식된 숫자 |
| Probability | out | natural 0~1023 | 신뢰도 (높을수록 확실) |

#### 제네릭

| 파라미터 | 기본값 | 설명 |
|----------|--------|------|
| Input_Columns | 448 | 입력 이미지 폭 |
| Input_Rows | 448 | 입력 이미지 높이 |
| Column_Offset | 80 | 수평 크롭 오프셋 |
| CNN_Columns | 28 | CNN 입력 폭 |
| CNN_Rows | 28 | CNN 입력 높이 |

#### 원본 대비 변경사항

| 항목 | 원본 (VHDP) | 변환 후 (VHDL) |
|------|-------------|----------------|
| Grayscale | `Pooling_iStream.R <= iStream.R` (R만 사용) | `Gray = (77R + 150G + 29B) >> 8` (BT.601) |
| 나머지 전부 | VHDP 문법 | 표준 VHDL (동일 로직) |

#### Argmax 로직

```vhdl
-- oCycle_1N = 0..9 순차 수신
if oCycle_1N = 0 then       -- 첫 출력: 초기화
    max_v := 0;
    max_number_v := 0;
end if;
if oData_1N(0) > max_v then -- 더 큰 값 발견
    max_v := oData_1N(0);
    max_number_v := oCycle_1N;
end if;
if oCycle_1N = 9 then       -- 마지막: 결과 확정
    Prediction  <= max_number_v;  -- 0~9
    Probability <= max_v;         -- 0~1023
end if;
```

---

## 변환 정합성 검증 결과

| 검증 항목 | 결과 |
|-----------|------|
| 제네릭 파라미터 값 | 원본과 동일 |
| 가중치 숫자값 (1,438개) | 원본과 동일 |
| 레이어 연결 순서/포트매핑 | 원본과 동일 |
| 활성화 함수 로직 | 원본과 동일 |
| MAC 연산 수식 | 원본과 동일 |
| ROM 초기화 함수 | 원본과 동일 |
| RAM 구조 (SUM/OUT/MAX/Buffer) | 원본과 동일 |
| Vivado 합성 | ERROR 0개 |
| 유일한 의도적 변경 | R-only -> RGB Grayscale 변환 |

---

## 파일 구조

```
cnn_vhdl/
  src/
    image_data_pkg.vhd      -- 이미지 타입 (rgb_stream 등)
    cnn_config_pkg.vhd       -- CNN 설정 (타입, 활성화 함수)
    cnn_data_pkg.vhd         -- 학습된 가중치 1,438개
    cnn_row_expander.vhd     -- 행 시간 확장기
    cnn_row_buffer.vhd       -- 컨볼루션 매트릭스 버퍼
    cnn_convolution.vhd      -- 2D 컨볼루션 레이어
    cnn_pooling.vhd          -- Max Pooling 레이어
    nn_layer.vhd             -- Fully Connected 레이어
    max_pooling_pre.vhd      -- 전처리 다운스케일 (448->28)
    rgb_to_cnn.vhd           -- RGB->CNN 스트림 변환
    cnn_top.vhd              -- 최상위 모듈
  create_project.tcl         -- Vivado 프로젝트 생성 스크립트
  CNN_VHDL_MODULE_GUIDE.md   -- 이 문서
```
