return {
  "sudormrfbin/cheatsheet.nvim",
  event = "VeryLazy",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "nvim-lua/popup.nvim",
    "nvim-lua/plenary.nvim",
  },
  config = function()
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    require("cheatsheet").setup({
      bundled_cheatsheets = true,
      bundled_plugin_cheatsheets = true,
      include_only_installed_plugins = true,
      telescope_mappings = {
        ["<CR>"] = actions.select_default,
        ["<C-Y>"] = function(prompt_bufnr)
          local selection = action_state.get_selected_entry(prompt_bufnr)
          if selection then
            vim.fn.setreg("+", selection.value or selection[1])
            vim.notify("Copied: " .. (selection.value or selection[1]), vim.log.levels.INFO)
          end
        end,
      },
    })
  end,
  specs = {
    {
      "AstroNvim/astrocore",
      opts = {
        mappings = {
          n = {
            ["<Leader>?"] = { "<cmd>Cheatsheet<cr>", desc = "Cheatsheet" },
          },
        },
      },
    },
  },
}
