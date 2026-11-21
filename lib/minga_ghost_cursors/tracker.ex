defmodule MingaGhostCursors.Tracker do
  @moduledoc """
  Tracks agent edit positions and manages ghost cursor overlays.

  Subscribes to `:buffer_changed` events, filters for agent-sourced
  edits, and registers overlays via `Minga.Extension.Overlay`. Monitors
  agent session PIDs so overlays are cleaned up when sessions end.
  """

  use GenServer

  alias Minga.Buffer.EditDelta
  alias Minga.Events
  alias Minga.Events.BufferChangedEvent
  alias Minga.Extension.AgentAPI
  alias Minga.Extension.Overlay

  @extension_name :minga_ghost_cursors
  @accent_color 0x7C3AED
  @cursor_opacity 102

  @host %{
    subscribe_edits: &AgentAPI.subscribe_edits/0,
    subscribe: &AgentAPI.subscribe/0,
    session_info: &AgentAPI.session_info/1,
    set_overlay: &Overlay.set/4,
    remove_overlay: &Overlay.remove/2,
    overlays: &Overlay.all/0,
    broadcast: &Events.broadcast/2
  }

  @type overlay_key :: {buffer :: pid(), session :: pid()}
  @type position :: {line :: non_neg_integer(), col :: non_neg_integer()}
  @type last_edit :: {overlay_key(), position()} | nil

  @typep session_info_result :: {:ok, %{label: String.t()}} | {:error, :not_found | :unavailable}

  @typep host :: %{
           subscribe_edits: (-> :ok),
           subscribe: (-> :ok),
           session_info: (pid() -> session_info_result()),
           set_overlay: (atom(), overlay_key(), pid(), keyword() -> :ok),
           remove_overlay: (atom(), overlay_key() -> :ok),
           overlays: (-> [Overlay.entry()]),
           broadcast: (Events.topic(), map() -> :ok)
         }

  @type state :: %{
          monitored: %{optional(pid()) => reference()},
          labels: %{optional(pid()) => String.t()},
          last_updated: last_edit(),
          host: host()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec last_updated(GenServer.server()) :: last_edit()
  def last_updated(server \\ __MODULE__) do
    GenServer.call(server, :last_updated)
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    host = Keyword.get(opts, :host, @host)
    host.subscribe_edits.()
    host.subscribe.()
    {:ok, %{monitored: %{}, labels: %{}, last_updated: nil, host: host}}
  end

  @impl true
  @spec handle_call(:last_updated, GenServer.from(), state()) :: {:reply, last_edit(), state()}
  def handle_call(:last_updated, _from, state) do
    {:reply, state.last_updated, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info(
        {:minga_event, :buffer_changed,
         %BufferChangedEvent{
           source: {:agent, session_pid, _tool_call_id},
           delta: %EditDelta{new_end_position: position},
           buffer: buffer_pid
         }},
        state
      ) do
    {label, state} = cached_label(state, session_pid)
    overlay_key = {buffer_pid, session_pid}

    state.host.set_overlay.(@extension_name, overlay_key, buffer_pid,
      position: position,
      content: label,
      style: %{fg: @accent_color, opacity: @cursor_opacity},
      shape: :cursor_with_label
    )

    state = maybe_monitor(state, session_pid)
    {:noreply, %{state | last_updated: {overlay_key, position}}}
  end

  def handle_info(
        {:minga_event, :buffer_changed, %BufferChangedEvent{}},
        state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {:minga_event, :agent_session_stopped, %{pid: session_pid}},
        state
      ) do
    {:noreply, stop_session(state, session_pid)}
  end

  def handle_info({:minga_event, :agent_hook, _payload}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, session_pid, _reason}, state) do
    {:noreply, stop_session(state, session_pid)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @spec cached_label(state(), pid()) :: {String.t(), state()}
  defp cached_label(state, session_pid) do
    case Map.fetch(state.labels, session_pid) do
      {:ok, label} ->
        {label, state}

      :error ->
        label = fetch_label(state.host, session_pid)
        {label, put_in(state.labels[session_pid], label)}
    end
  end

  @spec fetch_label(host(), pid()) :: String.t()
  defp fetch_label(host, session_pid) do
    case host.session_info.(session_pid) do
      {:ok, %{label: label}} -> label
      {:error, _reason} -> "agent"
    end
  catch
    :exit, _ -> "agent"
  end

  @spec maybe_monitor(state(), pid()) :: state()
  defp maybe_monitor(state, session_pid) do
    if Map.has_key?(state.monitored, session_pid) do
      state
    else
      ref = Process.monitor(session_pid)
      put_in(state.monitored[session_pid], ref)
    end
  end

  @spec stop_session(state(), pid()) :: state()
  defp stop_session(state, session_pid) do
    {removed?, state} = remove_session_overlays(state, session_pid)

    if removed? do
      state.host.broadcast.(:ghost_cursor_removed, %{session_pid: session_pid})
    end

    state
  end

  @spec remove_session_overlays(state(), pid()) :: {boolean(), state()}
  defp remove_session_overlays(state, session_pid) do
    Enum.each(state.host.overlays.(), fn
      %{extension: @extension_name, overlay_id: {_, ^session_pid} = key} ->
        state.host.remove_overlay.(@extension_name, key)

      _other ->
        :ok
    end)

    state = clear_last_updated(state, session_pid)
    state = %{state | labels: Map.delete(state.labels, session_pid)}

    case Map.pop(state.monitored, session_pid) do
      {nil, _monitored} ->
        {false, state}

      {ref, new_monitored} ->
        Process.demonitor(ref, [:flush])
        {true, %{state | monitored: new_monitored}}
    end
  end

  @spec clear_last_updated(state(), pid()) :: state()
  defp clear_last_updated(%{last_updated: {{_buf, session_pid}, _pos}} = state, session_pid) do
    %{state | last_updated: nil}
  end

  defp clear_last_updated(state, _session_pid), do: state
end
