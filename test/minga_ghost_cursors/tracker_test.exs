defmodule MingaGhostCursors.TrackerTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.EditDelta
  alias Minga.Events.BufferChangedEvent
  alias MingaGhostCursors.Tracker
  alias MingaGhostCursors.TrackerHost

  setup do
    store = start_supervised!({Agent, fn -> %{sessions: %{}, overlays: %{}} end})
    tracker = start_supervised!({Tracker, name: nil, host: TrackerHost.callbacks(store, self())})
    %{tracker: tracker, store: store}
  end

  test "subscribes to buffer edits and session lifecycle events" do
    assert_receive {:subscribed, :buffer_changed}
    assert_receive {:subscribed, :agent_session_stopped}
  end

  defp agent_edit_event(buffer_pid, session_pid, position) do
    {:minga_event, :buffer_changed,
     %BufferChangedEvent{
       buffer: buffer_pid,
       source: {:agent, session_pid, "tool_call_1"},
       delta: edit_delta(position),
       version: 1
     }}
  end

  defp edit_delta(position) do
    %EditDelta{
      start_byte: 0,
      old_end_byte: 0,
      new_end_byte: 5,
      start_position: {0, 0},
      old_end_position: {0, 0},
      new_end_position: position,
      inserted_text: "hello"
    }
  end

  defp spawn_waiting do
    spawn(fn -> receive do: (:stop -> :ok) end)
  end

  describe "buffer_changed events" do
    test "registers a labeled overlay for agent-sourced edits", %{tracker: tracker, store: store} do
      buffer_pid = spawn_waiting()
      session_pid = spawn_waiting()
      TrackerHost.set_label(store, session_pid, "Code reviewer")

      send(tracker, agent_edit_event(buffer_pid, session_pid, {5, 10}))
      wait_for_processing(tracker)

      overlays = TrackerHost.overlays(store)
      assert length(overlays) == 1

      [overlay] = overlays
      assert overlay.extension == :minga_ghost_cursors
      assert overlay.overlay_id == {buffer_pid, session_pid}
      assert overlay.buffer == buffer_pid
      assert overlay.position == {5, 10}
      assert overlay.content == "Code reviewer"
      assert overlay.shape == :cursor_with_label
      assert overlay.style == %{fg: 0x7C3AED, opacity: 102}

      Process.exit(buffer_pid, :kill)
      Process.exit(session_pid, :kill)
    end

    test "updates overlay position on subsequent edits", %{tracker: tracker, store: store} do
      buffer_pid = spawn_waiting()
      session_pid = spawn_waiting()

      send(tracker, agent_edit_event(buffer_pid, session_pid, {5, 10}))
      wait_for_processing(tracker)

      send(tracker, agent_edit_event(buffer_pid, session_pid, {12, 3}))
      wait_for_processing(tracker)

      overlays = TrackerHost.overlays(store)
      assert length(overlays) == 1
      assert hd(overlays).position == {12, 3}
      assert hd(overlays).content == "agent"

      Process.exit(buffer_pid, :kill)
      Process.exit(session_pid, :kill)
    end

    test "ignores non-agent edits", %{tracker: tracker, store: store} do
      event =
        {:minga_event, :buffer_changed,
         %BufferChangedEvent{
           buffer: self(),
           source: :user,
           delta: edit_delta({1, 5}),
           version: 1
         }}

      send(tracker, event)
      wait_for_processing(tracker)

      assert TrackerHost.overlays(store) == []
    end

    test "ignores agent edits without a delta", %{tracker: tracker, store: store} do
      session_pid = spawn_waiting()

      event =
        {:minga_event, :buffer_changed,
         %BufferChangedEvent{
           buffer: self(),
           source: {:agent, session_pid, "tool_1"},
           delta: nil,
           version: 1
         }}

      send(tracker, event)
      wait_for_processing(tracker)

      assert TrackerHost.overlays(store) == []

      Process.exit(session_pid, :kill)
    end

    test "tracks overlays per buffer per session", %{tracker: tracker, store: store} do
      buf1 = spawn_waiting()
      buf2 = spawn_waiting()
      session = spawn_waiting()

      send(tracker, agent_edit_event(buf1, session, {1, 0}))
      send(tracker, agent_edit_event(buf2, session, {2, 0}))
      wait_for_processing(tracker)

      assert length(TrackerHost.overlays(store)) == 2

      Process.exit(buf1, :kill)
      Process.exit(buf2, :kill)
      Process.exit(session, :kill)
    end

    test "tracks last_updated overlay key", %{tracker: tracker} do
      buf = spawn_waiting()
      session = spawn_waiting()

      send(tracker, agent_edit_event(buf, session, {5, 10}))
      wait_for_processing(tracker)

      assert Tracker.last_updated(tracker) == {{buf, session}, {5, 10}}

      Process.exit(buf, :kill)
      Process.exit(session, :kill)
    end
  end

  describe "session cleanup" do
    test "removes overlays when session PID exits", %{tracker: tracker, store: store} do
      buffer_pid = spawn_waiting()
      session_pid = spawn_waiting()

      send(tracker, agent_edit_event(buffer_pid, session_pid, {5, 10}))
      wait_for_processing(tracker)

      assert length(TrackerHost.overlays(store)) == 1

      Process.exit(session_pid, :kill)
      assert_receive {:minga_event, :ghost_cursor_removed, %{session_pid: ^session_pid}}

      assert TrackerHost.overlays(store) == []

      Process.exit(buffer_pid, :kill)
    end

    test "removes overlays on agent_session_stopped event", %{tracker: tracker, store: store} do
      buffer_pid = spawn_waiting()
      session_pid = spawn_waiting()

      send(tracker, agent_edit_event(buffer_pid, session_pid, {5, 10}))
      wait_for_processing(tracker)

      send(tracker, {:minga_event, :agent_session_stopped, %{pid: session_pid}})
      assert_receive {:minga_event, :ghost_cursor_removed, %{session_pid: ^session_pid}}

      assert TrackerHost.overlays(store) == []

      Process.exit(buffer_pid, :kill)
      Process.exit(session_pid, :kill)
    end

    test "only removes overlays for the stopped session", %{tracker: tracker, store: store} do
      buf = spawn_waiting()
      session1 = spawn_waiting()
      session2 = spawn_waiting()

      send(tracker, agent_edit_event(buf, session1, {1, 0}))
      send(tracker, agent_edit_event(buf, session2, {2, 0}))
      wait_for_processing(tracker)

      assert length(TrackerHost.overlays(store)) == 2

      send(tracker, {:minga_event, :agent_session_stopped, %{pid: session1}})
      assert_receive {:minga_event, :ghost_cursor_removed, %{session_pid: ^session1}}

      overlays = TrackerHost.overlays(store)
      assert length(overlays) == 1
      assert hd(overlays).overlay_id == {buf, session2}

      Process.exit(buf, :kill)
      Process.exit(session1, :kill)
      Process.exit(session2, :kill)
    end

    test "does not broadcast duplicate removal for same session", %{
      tracker: tracker,
      store: store
    } do
      buffer_pid = spawn_waiting()
      session_pid = spawn_waiting()

      send(tracker, agent_edit_event(buffer_pid, session_pid, {5, 10}))
      wait_for_processing(tracker)

      send(tracker, {:minga_event, :agent_session_stopped, %{pid: session_pid}})
      assert_receive {:minga_event, :ghost_cursor_removed, %{session_pid: ^session_pid}}

      send(tracker, {:minga_event, :agent_session_stopped, %{pid: session_pid}})
      wait_for_processing(tracker)

      refute_receive {:minga_event, :ghost_cursor_removed, _}

      assert TrackerHost.overlays(store) == []

      next_session = spawn_waiting()
      send(tracker, agent_edit_event(buffer_pid, next_session, {6, 11}))
      assert Tracker.last_updated(tracker) == {{buffer_pid, next_session}, {6, 11}}
      assert [%{overlay_id: {^buffer_pid, ^next_session}}] = TrackerHost.overlays(store)
      Process.exit(next_session, :kill)

      Process.exit(buffer_pid, :kill)
      Process.exit(session_pid, :kill)
    end

    test "clears last_updated when session is cleaned up", %{tracker: tracker} do
      buf = spawn_waiting()
      session = spawn_waiting()

      send(tracker, agent_edit_event(buf, session, {5, 10}))
      wait_for_processing(tracker)

      assert Tracker.last_updated(tracker) == {{buf, session}, {5, 10}}

      send(tracker, {:minga_event, :agent_session_stopped, %{pid: session}})
      assert_receive {:minga_event, :ghost_cursor_removed, %{session_pid: ^session}}

      assert Tracker.last_updated(tracker) == nil

      Process.exit(buf, :kill)
      Process.exit(session, :kill)
    end
  end

  defp wait_for_processing(tracker) do
    Tracker.last_updated(tracker)
  end
end
