# Minga Ghost Cursors

Show a labeled ghost cursor where an agent last edited each buffer. The cursor moves on subsequent edits and disappears when the agent session ends.

## Install

Use a [Minga](https://github.com/jsmestad/minga) build that includes the extension notice API from [issue #3764](https://github.com/jsmestad/minga/issues/3764). Add this line to `~/.config/minga/config.exs` after `use Minga.Config`, then restart Minga and approve the install when prompted:

```elixir
extension :minga_ghost_cursors, git: "https://github.com/jsmestad/minga-ghost-cursors"
```

Press `SPC a G` in normal mode to jump to the most recent agent edit position.

## Development

Use the Elixir and Erlang/OTP versions in the [CI workflow](.github/workflows/ci.yml). The SDK is a compile-time dependency; Minga supplies the real editor APIs at runtime.

```sh
export MIX_ENV=test
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix credo
mix test --warnings-as-errors
```

[MIT License](LICENSE)
