# Pair Policy Schema

이 문서는 `PairDefinitions`, `PairPolicies`, `pair-state.json` 의 운영 스키마를 고정한다.

## PairDefinitions

위치:

- config: `PairTest.PairDefinitions`
- manifest: `PairTest.PairDefinitions`

필수 필드:

- `PairId`
- `TopTargetId`
- `BottomTargetId`

선택 필드:

- `SeedTargetId`

규칙:

- `PairId` 는 중복되면 안 된다.
- `TopTargetId` 와 `BottomTargetId` 는 서로 달라야 한다.
- 하나의 target 은 둘 이상의 pair 에 동시에 속할 수 없다.
- `SeedTargetId` 를 명시하면 반드시 `TopTargetId | BottomTargetId` 중 하나여야 한다.
- `SeedTargetId` 가 없으면 기본값은 `TopTargetId` 다.

## PairPolicies

위치:

- config: `PairTest.PairPolicies.<PairId>`
- manifest: `PairTest.PairPolicies.<PairId>`

허용 pair key:

- 반드시 `PairDefinitions` 에 이미 있는 `PairId` 여야 한다.

지원 필드:

- `DefaultSeedTargetId`
- `DefaultSeedWorkRepoRoot`
- `DefaultSeedReviewInputPath`
- `DefaultSeedReviewInputSearchRelativePath`
- `DefaultSeedReviewInputFilter`
- `DefaultSeedReviewInputNameRegex`
- `DefaultSeedReviewInputMaxAgeHours`
- `DefaultSeedReviewInputRequireSingleCandidate`
- `DefaultWatcherMaxForwardCount`
- `DefaultWatcherRunDurationSec`
- `DefaultPairMaxRoundtripCount`
- `PublishContractMode`
- `RecoveryPolicy`
- `PauseAllowed`

기본값 fallback 순서:

1. `PairPolicies.<PairId>.*`
2. `PairTest.Default*`
3. 코드 기본값

핵심 기본값:

- `DefaultWatcherMaxForwardCount = 0`
- `DefaultWatcherRunDurationSec = 900`
- `DefaultPairMaxRoundtripCount = 0`
- `PublishContractMode = strict`
- `RecoveryPolicy = manual-review`
- `PauseAllowed = true`

검증 규칙:

- `DefaultWatcherMaxForwardCount`, `DefaultWatcherRunDurationSec`, `DefaultPairMaxRoundtripCount` 는 음수가 될 수 없다.
- `DefaultSeedTargetId` 를 명시하면 반드시 해당 pair 의 top/bottom target 중 하나여야 한다.
- unknown pair key 는 즉시 실패한다.

운영 의미:

- `DefaultPairMaxRoundtripCount > 0` 이면 watcher global limit 가 0일 때 pair별 왕복 limit 로 사용된다.
- `RecoveryPolicy` 와 `PauseAllowed` 는 status/panel 진단과 운영 문구에 함께 노출된다.

## pair-state.json

위치:

- `RunRoot\.state\pair-state.json`

현재 schema version:

- `1.0.0`

상위 필드:

- `SchemaVersion`
- `RunRoot`
- `UpdatedAt`
- `Pairs`

pair row 필드:

- `PairId`
- `TopTargetId`
- `BottomTargetId`
- `SeedTargetId`
- `ForwardCount`
- `RoundtripCount`
- `CurrentPhase`
- `NextAction`
- `HandoffReadyCount`
- `NextExpectedSourceTargetId`
- `NextExpectedTargetId`
- `NextExpectedHandoff`
- `LastFromTargetId`
- `LastToTargetId`
- `LastForwardedAt`
- `LastForwardedZipPath`
- `StateSummary`
- `ConfiguredMaxRoundtripCount`
- `LimitReached`
- `LimitReachedAt`
- `Paused`
- `UpdatedAt`

phase canonical enum:

- `seed-running`
- `partner-running`
- `waiting-partner-handoff`
- `waiting-return`
- `paused`
- `limit-reached`
- `manual-attention`
- `error-blocked`
- `completed`

phase normalize alias:

- `waiting-handoff -> waiting-partner-handoff`
- `manual-review -> manual-attention`

운영 규칙:

- `pair-state.json` 이 있으면 status/panel 은 계산 fallback 보다 이 값을 우선 사용한다.
- schema version 이 없으면 `legacy-missing` 경고와 함께 현재 버전으로 가정한다.
- 지원하지 않는 schema version 이면 `unsupported` 경고를 남기되, 읽을 수 있는 필드는 계속 surface 한다.

## 관련 회귀

- `tests\Test-PairedExchangeConfigValidation.ps1`
- `tests\Test-ResolvePairTestConfigPairDefinitions.ps1`
- `tests\Test-WatcherPerPairPolicyRoundtripLimit.ps1`
- `tests\Test-WatcherPolicyRoundtripLimitStop.ps1`
- `tests\Test-ShowPairedExchangeStatusPairStatePreference.ps1`
- `tests\Test-ShowPairedExchangeStatusPairStateSchemaVersion.ps1`
