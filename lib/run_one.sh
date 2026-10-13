#!/usr/bin/env bash
# 1資源の処理の流れ（骨格）
#
# 手動（bin/ref）と自動（lib/process_inbox.sh）が共有する．
# 経路ごとに違うのは次の2つの関数だけで，呼び出し側が定義して差し替える．
#
#   prepare_target   対象を作業ディレクトリへ用意する（手動=コピー／自動=mv で確保）
#                    失敗したら 1 を返す．その場合は記録も通知もせず静かに終わる．
#   place_result     結果に応じてファイルを配置する（手動=原本を改名／自動=改名して移動）
#                    引数は成功なら 1．返り値 0=配置できた，1=配置できなかった．
#                    PLACEMENT に配置結果の説明，PLACED_AT にファイルの現在地を設定する．
#
# 呼び出し側が設定する変数:
#   RUN_MODE         auto | manual
#   TARGET_KIND      file | url
#   TARGET_LABEL     通知やログに出す表示名
#   TARGET_DESC      プロンプトの「今回の対象」に入れる記述
#   AUX_DESC         プロンプトの「補助資料」に入れる記述（空でよい）

prepare_target() { return 0; }
place_result()   { PLACEMENT=""; PLACED_AT=""; return 0; }

run_one() {
  local analyzed=0 placed=0

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

  # 開始の通知は枠を取得した後に出す（待機中のものは出さない）
  notify_start "$TARGET_LABEL"

  analyze "$TARGET_DESC" "${AUX_DESC:-}" && analyzed=1

  PLACEMENT=""; PLACED_AT=""
  place_result "$analyzed" && placed=1

  save_records

  # 終端の4状態．必要な作業が異なるため区別して通知する．
  if [ "$analyzed" = "1" ] && [ "$placed" = "1" ]; then
    notify_done "$PLACEMENT"
    release_slot
    cleanup_work_dir
    return 0
  fi

  if [ "$analyzed" = "1" ]; then
    # 登録は完了したがファイルの配置に失敗した
    log_msg "要配置: ${ERROR_MESSAGE:-配置に失敗した}"
    notify_needs_placement "${PLACED_AT:-$WORK_DIR}"
    release_slot
    return 1
  fi

  log_msg "失敗: ${ERROR_MESSAGE:-不明}"
  if [ -n "${NOTION_URL:-}" ]; then
    # ページは作られている．再実行すると重複するため区別する．
    notify_needs_repair "$TARGET_LABEL" "${PLACED_AT:-}"
  else
    notify_failed "$TARGET_LABEL"
  fi
  release_slot
  # 失敗時は調査用に作業ディレクトリを残す（保存期間の削除対象に含める）
  return 1
}
