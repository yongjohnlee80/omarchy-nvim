return {
  {
    "yongjohnlee80/worktree.nvim",
    event = "VeryLazy",
    opts = {
      lsp_servers_to_restart = { "gopls" },
    },
    keys = {
      { "<leader>gw", function() require("worktree").pick() end, desc = "Worktree: switch" },
      { "<leader>gW", function() require("worktree").home() end, desc = "Worktree: back to root" },
      { "<leader>gA", function() require("worktree").add() end, desc = "Worktree: add" },
      { "<leader>gR", function() require("worktree").remove() end, desc = "Worktree: remove" },
    },
  },
}
