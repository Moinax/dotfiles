-- if true then return {} end -- WARN: REMOVE THIS LINE TO ACTIVATE THIS FILE

-- AstroUI provides the basis for configuring the AstroNvim User Interface
-- Configuration documentation can be found with `:h astroui`
-- NOTE: We highly recommend setting up the Lua Language Server (`:LspInstall lua_ls`)
--       as this provides autocomplete and documentation while editing

-- Read catppuccin flavor from state file (set by apply-dark-mode.sh)
local flavor = "mocha"
local f = io.open(vim.fn.expand("~/.local/share/nvim-theme"), "r")
if f then
  local content = f:read("*l")
  f:close()
  if content == "latte" or content == "mocha" or content == "frappe" or content == "macchiato" then
    flavor = content
  end
end

---@type LazySpec
return {
  {
    "AstroNvim/astroui",
    ---@type AstroUIOpts
    opts = {
      -- change colorscheme
      colorscheme = "catppuccin",
      status = {
        separators = {
          left = { "", "" },
          right = { " ", "" },
          tab = { "", "" },
        },
      },
    },
  },
  {
    "catppuccin/nvim",
    name = "catppuccin",
    opts = {
      flavour = flavor,
    },
  },
}
