# Relay Panel Refactor Baseline

이 문서는 `relay_operator_panel.py` 리팩토링 기준선 검증과 review bundle 계약을 짧게 고정하기 위한 메모다.

## Baseline Commands

PowerShell 진입점:

```powershell
Set-Location 'C:\dev\python\hyukwoo\hyukwoo1'
.\run-relay-panel-refactor-baseline.ps1
```

Raw compile 명령:

```powershell
Set-Location 'C:\dev\python\hyukwoo\hyukwoo1'
python -m py_compile .\relay_operator_panel.py .\relay_panel_operator_state.py .\relay_panel_visible_workflow.py .\relay_panel_context_helpers.py .\relay_test_temp.py .\test_relay_panel_refactors.py .\test_relay_panel_context_helpers.py .\test_relay_panel_visible_workflow.py .\test_relay_panel_operator_state.py
```

Raw unittest 명령:

```powershell
Set-Location 'C:\dev\python\hyukwoo\hyukwoo1'
python -m unittest -q test_relay_panel_refactors.py test_relay_panel_context_helpers.py test_relay_panel_visible_workflow.py test_relay_panel_operator_state.py
```

## Tempfile Note

현재 Windows 환경에서는 기본 `%TEMP%` 경로 ACL 문제로 `tempfile.TemporaryDirectory()`가 불안정할 수 있다.
`test_relay_panel_refactors.py`는 `relay_test_temp.py`를 통해 모듈 범위에서 workspace temp 루트를 사용한다.

## Review Bundle Contract

review bundle은 기본적으로 "변경 파일 위주 delta bundle" 이다.

따라서 다음 정보를 함께 남기는 것을 권장한다.

1. 변경 파일 목록
2. 로컬에서 실제로 실행한 compile / test 명령
3. 전체 repo 필요 여부
4. known limitation

주의:

- zip 안에 변경 파일만 있으면 외부에서 `py_compile`은 가능해도 전체 unittest 재현은 전체 repo가 필요할 수 있다.
- bundle 검토자는 이 문서나 같은 수준의 `REVIEW-NOTES.md`를 기준으로 재현 범위를 판단한다.
