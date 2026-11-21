defmodule MingaGhostCursors.TrackerHost do
  @moduledoc false

  @spec callbacks(pid(), pid()) :: map()
  def callbacks(store, listener) do
    %{
      subscribe_edits: fn -> notify(listener, {:subscribed, :buffer_changed}) end,
      subscribe: fn -> notify(listener, {:subscribed, :agent_session_stopped}) end,
      session_info: fn session -> session_info(store, session) end,
      set_overlay: fn extension, id, buffer, opts ->
        set_overlay(store, extension, id, buffer, opts)
      end,
      remove_overlay: fn extension, id -> remove_overlay(store, extension, id) end,
      overlays: fn -> overlays(store) end,
      broadcast: fn topic, payload -> notify(listener, {:minga_event, topic, payload}) end
    }
  end

  @spec set_label(pid(), pid(), String.t()) :: :ok
  def set_label(store, session, label) do
    Agent.update(store, &put_in(&1.sessions[session], %{label: label}))
  end

  @spec overlays(pid()) :: [Minga.Extension.Overlay.entry()]
  def overlays(store), do: Agent.get(store, &Map.values(&1.overlays))

  defp session_info(store, session) do
    Agent.get(store, fn state ->
      case Map.fetch(state.sessions, session) do
        {:ok, info} -> {:ok, info}
        :error -> {:error, :not_found}
      end
    end)
  end

  defp set_overlay(store, extension, id, buffer, opts) do
    entry = Enum.into(opts, %{extension: extension, overlay_id: id, buffer: buffer})
    Agent.update(store, &put_in(&1.overlays[{extension, id}], entry))
  end

  defp remove_overlay(store, extension, id) do
    Agent.update(store, fn state ->
      update_in(state.overlays, &Map.delete(&1, {extension, id}))
    end)
  end

  defp notify(listener, message) do
    send(listener, message)
    :ok
  end
end
