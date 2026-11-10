local M = {}

function M.get_common_options()
  return {
    shortcuts = {
      close_tab = "q",
      jump_to_first = "F",
      activate = { "<CR>", "<2-LeftMouse>" },
      scroll_backward = "<C-b>",
      scroll_forward = "<C-f>",
      prev_file = "<S-TAB>",
      next_file = "<TAB>",
      focus_panel = "<leader>p",
      focus_first_file = "<leader>1",
      focus_second_file = "<leader>2",
      focus_third_file = "<leader>3",
      focus_fourth_file = "<leader>4",
      mark_file_for_diff = {"+", "kPlus"},
    }
  }
end

function M.get_log_options()
  return vim.tbl_deep_extend("force", M.get_common_options(), {
    shortcuts = {
      filters = "g!",
      yank_commit = "<C-y>",
      open_log = "L",
    },
    relative_date_cutoff_seconds = 3 * 24 * 60 * 60,
    default_max_items = 256,
    panel_width = function() return 43 end, -- calculated for render_commit_section to fit
  })
end

function M.get_stashes_options()
  return vim.tbl_deep_extend("force", M.get_log_options(), {
    shortcuts = {
      unstash = "<C-enter>",
      drop_stash = "<C-del>",
    },
  })
end

function M.get_diff_options()
  return vim.tbl_deep_extend("force", M.get_common_options(), {
    shortcuts = {
      yank_commit = "<C-y>",
    },
    panel_width = function() return 43 end, -- calculated for render_commit_section to fit
  })
end

function M.get_revspec_options()
  return vim.tbl_deep_extend("force", M.get_diff_options(), {
    shortcuts = {
      open_log = "L",
    },
    diff_log_panel_height_ratio = 0.6,
    relative_date_cutoff_seconds = 3 * 24 * 60 * 60,
  })
end

function M.get_status_options()
  return vim.tbl_deep_extend("force", M.get_diff_options(), {
    shortcuts = {
      stage_unstage = "s",
      stage_all = "S",
      unstage_all = "U",
      drop_changes = "X",
      open_conflict_commits = "L",
      conflict_modal_switch_commit = "<TAB>",
      conflict_previous = "[x",
      conflict_next = "]x",
      conflict_choose_ours = "<leader>co",
      conflict_choose_theirs = "<leader>ct",
      conflict_choose_all = "<leader>ca",
      all_conflicts_choose_ours = "<leader>cO",
      all_conflicts_choose_theirs = "<leader>cT",
      all_conflicts_choose_all = "<leader>cA",
    },
    conflicts_display_mode = "ours_local_theirs", -- also supported: ours_local_theirs_base
  })
end

function M.apply_option_defaults(opts, defaults)
  return vim.tbl_deep_extend("keep", opts or {}, defaults)
end

return M
