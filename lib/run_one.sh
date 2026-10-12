#!/usr/bin/env bash
# 1資源の処理の流れ（骨格）
#
# 手動（bin/ref）と自動（lib/process_inbox.sh）が共有する．
# 経路ごとに違うのは次の2つの関数だけで，呼び出し側が定義して差し替える．
#
#   prepare_target   対象を作業ディレクトリへ用意する（手動=コピー／自動=mv で確保）
#                    失敗したら 1 を返す．その場合は記録も通知もせず静かに終わる．
#   place_result     結果に応じてファイルを配置する（手動=原本を改名／自動=改名して移動）
#
# 呼び出し側が設定する変数:
#   TARGET_KIND      file | url
#   TARGET_LABEL     通知やログに出す表示名
#   TARGET_DESC      プロンプトの「今回の対象」に入れる記述
#   AUX_DESC         プロンプトの「補助資料」に入れる記述（空でよい）
#   PLACEMENT        通知に出す配置の説明（place_result が設定する）

# 既定の実装（呼び出し側が上書きする）
prepare_target() { return 0; }
place_result()   { PLACEMENT=""; return 0; }

run_one() {
  local ok=0

  # 枠は「1資源を処理する許可」である．先に取るので，待っているプロセスは
  # 対象ファイルを掴まない．これが唯一の同時実行の制御点である．
  acquire_slot || true
  begin_run "$TARGET_KIND"

  if ! prepare_target; then
    log_msg "対象を用意できなかった．何もせず終了する"
    release_slot
    discard_run_dirs
    return 0
  fi

  if analyze "$TARGET_DESC" "${AUX_DESC:-}"; then
    ok=1
  fi

  place_result "$ok" || ok=0

  save_records
  if [ "$ok" = "1" ]; then
    notify_success "${PLACEMENT:-}"
  else
    log_msg "失敗: ${ERROR_MESSAGE:-不明}"
    notify_failure "$TARGET_LABEL"
  fi

  release_slot

  if [ "$ok" = "1" ]; then
    cleanup_work_dir
    return 0
  fi
  # 失敗時は調査用に作業ディレクトリを残す（保存期間の削除対象に含める）
  return 1
}
