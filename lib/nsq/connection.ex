defmodule NSQ.Connection do
  @moduledoc """
  Sets up a TCP connection to NSQD. Both consumers and producers use this.

  This implements the Connection behaviour, which lets us reconnect or backoff
  under certain conditions. For more info, check out the module:
  https://github.com/fishcakez/connection. The module docs are especially
  helpful:
  https://github.com/fishcakez/connection/blob/master/lib/connection.ex.
  """

  # ------------------------------------------------------- #
  # Directives                                              #
  # ------------------------------------------------------- #
  require Logger
  require HTTPotion
  require HTTPotion.Response
  import NSQ.Protocol
  alias NSQ.ConnInfo, as: ConnInfo

  # ------------------------------------------------------- #
  # Type Definitions                                        #
  # ------------------------------------------------------- #
  @typedoc """
  A tuple with a host and a port.
  """
  @type host_with_port :: {String.t, integer}

  @typedoc """
  A tuple with a string ID (used to target the connection in
  NSQ.ConnectionSupervisor) and a PID of the connection.
  """
  @type connection :: {String.t, pid}

  @typedoc """
  A map, but we can be more specific by asserting some entries that should be
  set for a connection's state map.
  """
  @type conn_state :: %{parent: pid, socket: pid, config: NSQ.Config.t, nsqd: host_with_port}

  # ------------------------------------------------------- #
  # Module Attributes                                       #
  # ------------------------------------------------------- #
  @project ElixirNsq.Mixfile.project
  @user_agent "#{@project[:app]}/#{@project[:version]}"
  @socket_opts [as: :binary, active: false, deliver: :term, packet: :raw]
  @initial_state %{
    parent: nil,
    socket: nil,
    cmd_resp_queue: :queue.new,
    cmd_queue: :queue.new,
    config: %{},
    reader_pid: nil,
    msg_sup_pid: nil,
    event_manager_pid: nil,
    messages_in_flight: 0,
    nsqd: nil,
    topic: nil,
    channel: nil,
    backoff_counter: 0,
    backoff_duration: 0,
    max_rdy: 2500,
    connect_attempts: 0,
    stop_flag: false,
    conn_info_pid: nil,
    msg_timeout: nil
  }

  # ------------------------------------------------------- #
  # Behaviour Implementation                                #
  # ------------------------------------------------------- #
  @spec init(map) :: {:ok, conn_state}
  def init(conn_state) do
    {:ok, msg_sup_pid} = NSQ.MessageSupervisor.start_link
    conn_state = %{conn_state | msg_sup_pid: msg_sup_pid}
    init_conn_info(conn_state)
    connect_result = connect(conn_state)
    case connect_result do
      {:ok, state} -> {:ok, state}
      {{:error, _reason}, state} -> {:ok, state}
    end
  end

  def terminate(_reason, _state) do
    :ok
  end


  @spec handle_call({:cmd, tuple, atom}, {pid, reference}, conn_state) ::
    {:reply, {:ok, reference}, conn_state} |
    {:reply, {:queued, :nosocket}, conn_state}
  def handle_call({:cmd, cmd, kind}, {_, ref} = from, state) do
    if state.socket do
      state = send_data_and_queue_resp(state, cmd, from, kind)
      state = update_state_from_cmd(cmd, state)
      {:reply, {:ok, ref}, state}
    else
      # Not connected currently; add this call onto a queue to be run as soon
      # as we reconnect.
      state = %{state | cmd_queue: :queue.in({cmd, from, kind}, state.cmd_queue)}
      {:reply, {:queued, :no_socket}, state}
    end
  end

  @spec handle_call(:stop, {pid, reference}, conn_state) ::
    {:stop, :normal, conn_state}
  def handle_call(:stop, _from, state) do
    {:stop, :normal, state}
  end

  @spec handle_call(:state, {pid, reference}, conn_state) ::
    {:reply, conn_state, conn_state}
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @spec handle_cast(:flush_cmd_queue, conn_state) :: {:noreply, conn_state}
  def handle_cast(:flush_cmd_queue, state) do
    {:noreply, flush_cmd_queue(state)}
  end

  @spec handle_cast({:nsq_msg, binary}, conn_state) :: {:noreply, conn_state}
  def handle_cast({:nsq_msg, msg}, %{socket: socket, cmd_resp_queue: cmd_resp_queue} = state) do
    case msg do
      {:response, "_heartbeat_"} ->
        GenEvent.notify(state.event_manager_pid, :heartbeat)
        socket |> Socket.Stream.send!(encode(:noop))

      {:response, data} ->
        GenEvent.notify(state.event_manager_pid, {:response, data})
        {item, cmd_resp_queue} = :queue.out(cmd_resp_queue)
        case item do
          {:value, {_cmd, {pid, ref}, :reply}} ->
            send(pid, {ref, data})
          :empty -> :ok
        end
        state = %{state | cmd_resp_queue: cmd_resp_queue}

      {:error, data} ->
        GenEvent.notify(state.event_manager_pid, {:error, data})
        Logger.error "error: #{inspect data}"

      {:error, reason, data} ->
        GenEvent.notify(state.event_manager_pid, {:error, reason, data})
        Logger.error "error: #{reason}\n#{inspect data}"

      {:message, data} ->
        message = NSQ.Message.from_data(data)
        state = received_message(state)
        message = %NSQ.Message{message |
          connection: self,
          consumer: state.parent,
          socket: socket,
          config: state.config,
          msg_timeout: state.msg_timeout,
          event_manager_pid: state.event_manager_pid
        }
        GenEvent.notify(state.event_manager_pid, {:message, message})
        GenServer.cast(state.parent, {:maybe_update_rdy, state.nsqd})
        NSQ.MessageSupervisor.start_child(state.msg_sup_pid, message)
    end

    {:noreply, state}
  end

  @spec handle_cast(:reconnect, conn_state) :: {:noreply, conn_state}
  def handle_cast(:reconnect, conn_state) do
    if conn_state.connect_attempts > 0 do
      {_, conn_state} = connect(conn_state)
    end
    {:noreply, conn_state}
  end

  # When a task is done, it automatically messages the return value to the
  # calling process. we can use that opportunity to update the messages in
  # flight.
  @spec handle_info({reference, {:message_done, NSQ.Message.t, any}}, conn_state) ::
    {:noreply, conn_state}
  def handle_info({:message_done, _msg, ret_val}, state) do
    update_conn_stats(state, ret_val)
    {:noreply, state}
  end

  defp update_conn_stats(state, ret_val) do
    ConnInfo.update state, fn(info) ->
      info = %{info | messages_in_flight: info.messages_in_flight - 1}
      case ret_val do
        :ok ->
          %{info | finished_count: info.finished_count + 1}
        :fail ->
          %{info | failed_count: info.failed_count + 1}
        :req ->
          %{info | requeued_count: info.requeued_count + 1}
        {:req, _} ->
          %{info | requeued_count: info.requeued_count + 1}
        {:req, _, true} ->
          %{info |
            requeued_count: info.requeued_count + 1,
            backoff_count: info.backoff_count + 1
          }
        {:req, _, _} ->
          %{info | requeued_count: info.requeued_count + 1}
      end
    end
  end

  # ------------------------------------------------------- #
  # API Definitions                                         #
  # ------------------------------------------------------- #
  @spec start_link(pid, host_with_port, NSQ.Config.t, String.t, String.t, pid, list) ::
    {:ok, pid}
  def start_link(parent, nsqd, config, topic, channel, conn_info_pid, event_manager_pid, opts \\ []) do
    state = %{@initial_state |
      parent: parent,
      nsqd: nsqd,
      config: config,
      topic: topic,
      channel: channel,
      conn_info_pid: conn_info_pid,
      event_manager_pid: event_manager_pid
    }
    {:ok, _pid} = GenServer.start_link(__MODULE__, state, opts)
  end

  @spec get_state(pid) :: {:ok, conn_state}
  def get_state(pid) when is_pid(pid) do
    GenServer.call(pid, :state)
  end

  @spec get_state(connection) :: {:ok, conn_state}
  def get_state({_conn_id, pid} = _connection) do
    get_state(pid)
  end

  @spec close(pid, conn_state) :: any
  def close(conn, conn_state \\ nil) do
    Logger.debug "Closing connection #{inspect conn}"
    conn_state = conn_state || get_state(conn)

    # send a CLS command and expect CLOSE_WAIT in response
    {:ok, "CLOSE_WAIT"} = cmd(conn, :cls)

    # grace period: poll once per second until zero are in flight
    result = wait_for_zero_in_flight_with_timeout(
      conn_state.conn_info_pid,
      ConnInfo.conn_id(conn_state),
      conn_state.msg_timeout
    )

    # either way, we're exiting
    case result do
      :ok ->
        Logger.warn "#{inspect conn}: No more messages in flight. Exiting."
      :timeout ->
        Logger.error "#{inspect conn}: Timed out waiting for messages to finish. Exiting anyway."
    end

    Process.exit(self, :normal)
  end

  @spec nsqds_from_lookupds([host_with_port], String.t) :: [host_with_port]
  def nsqds_from_lookupds(lookupds, topic) do
    responses = Enum.map(lookupds, &query_lookupd(&1, topic))
    nsqds = Enum.map responses, fn(response) ->
      Enum.map response["producers"] || [], fn(producer) ->
        if producer do
          {producer["broadcast_address"], producer["tcp_port"]}
        else
          nil
        end
      end
    end
    nsqds |>
      List.flatten |>
      Enum.uniq |>
      Enum.reject(fn(v) -> v == nil end)
  end

  @spec query_lookupd(host_with_port, String.t) :: map
  def query_lookupd({host, port}, topic) do
    lookupd_url = "http://#{host}:#{port}/lookup?topic=#{topic}"
    headers = [{"Accept", "application/vnd.nsq; version=1.0"}]
    try do
      case HTTPotion.get(lookupd_url, headers: headers) do
        %HTTPotion.Response{status_code: 200, body: body, headers: headers} ->
          if body == nil || body == "" do
            body = "{}"
          end

          if headers[:"X-Nsq-Content-Type"] == "nsq; version=1.0" do
            Poison.decode!(body)
          else
            %{status_code: 200, status_txt: "OK", data: body}
          end
        %HTTPotion.Response{status_code: 404} ->
          %{}
        %HTTPotion.Response{status_code: status, body: body} ->
          Logger.error "Unexpected status code from #{lookupd_url}: #{status}"
          %{status_code: status, status_txt: nil, data: body}
      end
    rescue
      e in HTTPotion.HTTPError ->
        Logger.error "Error connecting to #{lookupd_url}: #{inspect e}"
        %{status_code: nil, status_txt: nil, data: nil}
    end
  end

  @doc """
  This is the recv loop that we kick off in a separate process immediately
  after the handshake. We send each incoming NSQ message as an erlang message
  back to the connection for handling.
  """
  def recv_nsq_messages(sock, conn, timeout) do
    case sock |> Socket.Stream.recv(4, timeout: timeout) do
      {:error, :timeout} ->
        # If publishing is quiet, we won't receive any messages in the timeout.
        # This is fine. Let's just try again!
        recv_nsq_messages(sock, conn, timeout)
      {:ok, <<msg_size :: size(32)>>} ->
        # Got a message! Decode it and let the connection know. We just
        # received data on the socket to get the size of this message, so if we
        # timeout in here, that's probably indicative of a problem.

        {:ok, raw_msg_data} =
          sock |> Socket.Stream.recv(msg_size, timeout: timeout)
        decoded = decode(raw_msg_data)
        GenServer.cast(conn, {:nsq_msg, decoded})
        recv_nsq_messages(sock, conn, timeout)
    end
  end

  @doc """
  Immediately after connecting to the NSQ socket, both consumers and producers
  follow this protocol.
  """
  @spec do_handshake(conn_state) :: {:ok, conn_state}
  def do_handshake(conn_state) do
    conn_state = Task.async(fn ->
      %{socket: socket, channel: channel} = conn_state

      socket |> send_magic_v2
      {:ok, conn_state} = socket |> identify(conn_state)

      # Producers don't have a channel, so they won't do this.
      if channel do
        socket |> subscribe(conn_state)
      end

      conn_state
    end) |> Task.await(conn_state.config.dial_timeout)

    {:ok, conn_state}
  end

  @doc """
  Calls the command and waits for a response. If a command shouldn't have a
  response, use cmd_noreply.
  """
  @spec cmd(pid, tuple, integer) :: {:ok, binary} | {:error, String.t}
  def cmd(conn_pid, cmd, timeout \\ 5000) do
    {:ok, ref} = GenServer.call(conn_pid, {:cmd, cmd, :reply})
    receive do
      {^ref, data} ->
        {:ok, data}
    after
      timeout ->
        {:error, "Command #{cmd} took longer than timeout #{timeout}"}
    end
  end

  @doc """
  Calls the command but doesn't generate a reply back to the caller.
  """
  @spec cmd_noreply(pid, tuple) :: {:ok, reference} | {:queued, :nosocket}
  def cmd_noreply(conn_pid, cmd) do
    GenServer.call(conn_pid, {:cmd, cmd, :noreply})
  end

  @doc """
  Calls the command but doesn't expect any response.
  """
  @spec cmd_noreply(pid, tuple) :: {:ok, reference} | {:queued, :nosocket}
  def cmd_noresponse(conn, cmd) do
    GenServer.call(conn, {:cmd, cmd, :noresponse})
  end

  # ------------------------------------------------------- #
  # Private Functions                                       #
  # ------------------------------------------------------- #
  @spec connect(%{nsqd: host_with_port}) :: {:ok, conn_state} | {:error, String.t}
  defp connect(%{nsqd: {host, port}} = state) do
    if should_connect?(state) do
      socket_opts =
        @socket_opts
        |> Keyword.put(:send_timeout, state.config.write_timeout)
        |> Keyword.put(:timeout, state.config.dial_timeout)

      case Socket.TCP.connect(host, port, socket_opts) do
        {:ok, socket} ->
          state = %{state | socket: socket}
          {:ok, state} = do_handshake(state)
          {:ok, state} = start_receiving_messages(socket, state)
          {:ok, reset_connects(state)}
        {:error, reason} ->
          if length(state.config.nsqlookupds) > 0 do
            Logger.warn "(#{inspect self}) connect failed; discovery loop should respawn"
            {{:error, reason}, %{state | connect_attempts: state.connect_attempts + 1}}
          else
            if state.config.max_reconnect_attempts > 0 do
              Logger.warn "(#{inspect self}) connect failed; #{reason}; discovery loop should respawn"
              {{:error, reason}, %{state | connect_attempts: state.connect_attempts + 1}}
            else
              Logger.error "(#{inspect self}) connect failed; reconnect turned off; terminating connection"
              Process.exit(self, :connect_failed)
            end
          end
      end
    else
      Logger.error "#{inspect self}: Failed to connect; terminating connection"
      Process.exit(self, :connect_failed)
    end
  end

  @spec should_connect?(conn_state) :: boolean
  defp should_connect?(state) do
    state.connect_attempts == 0 ||
      state.connect_attempts <= state.config.max_reconnect_attempts
  end

  @spec send_magic_v2(pid) :: :ok
  defp send_magic_v2(socket) do
    Logger.debug("(#{inspect self}) sending magic v2...")
    socket |> Socket.Stream.send!(encode(:magic_v2))
  end

  @spec identify(pid, conn_state) :: {:ok, binary}
  defp identify(socket, conn_state) do
    Logger.debug("(#{inspect self}) identifying...")
    identify_obj = encode({:identify, identify_props(conn_state)})
    socket |> Socket.Stream.send!(identify_obj)
    {:response, json} = recv_nsq_response(socket, conn_state)
    {:ok, _conn_state} = update_from_identify_response(conn_state, json)
  end

  @spec update_from_identify_response(map, binary) :: map
  defp update_from_identify_response(conn_state, json) do
    {:ok, parsed} = Poison.decode(json)

    # respect negotiated max_rdy_count
    if parsed["max_rdy_count"] do
      ConnInfo.update conn_state, %{max_rdy: parsed["max_rdy_count"]}
    end

    # respect negotiated msg_timeout
    if parsed["msg_timeout"] do
      conn_state = %{conn_state | msg_timeout: parsed["msg_timeout"]}
    else
      conn_state = %{conn_state | msg_timeout: conn_state.config.msg_timeout}
    end

    {:ok, conn_state}
  end

  @spec recv_nsq_response(pid, map) :: {:response, binary}
  defp recv_nsq_response(socket, conn_state) do
    {:ok, <<msg_size :: size(32)>>} =
      socket |>
      Socket.Stream.recv(4, timeout: conn_state.config.read_timeout)

    {:ok, raw_msg_data} =
      socket |>
      Socket.Stream.recv(msg_size, timeout: conn_state.config.read_timeout)

    {:response, _response} = decode(raw_msg_data)
  end

  @spec subscribe(pid, conn_state) :: {:ok, binary}
  defp subscribe(socket, %{topic: topic, channel: channel} = conn_state) do
    Logger.debug "(#{inspect self}) subscribe to #{topic} #{channel}"
    socket |>
    Socket.Stream.send!(encode({:sub, topic, channel}))

    Logger.debug "(#{inspect self}) wait for subscription acknowledgment"
    expected = ok_msg
    {:ok, ^expected} =
      socket |>
      Socket.Stream.recv(byte_size(expected), timeout: conn_state.config.read_timeout)
  end

  @spec identify_props(conn_state) :: conn_state
  defp identify_props(%{nsqd: {host, port}, config: config} = conn_state) do
    %{
      client_id: "#{host}:#{port} (#{inspect conn_state.parent})",
      hostname: to_string(:net_adm.localhost),
      feature_negotiation: true,
      heartbeat_interval: config.heartbeat_interval,
      output_buffer: config.output_buffer_size,
      output_buffer_timeout: config.output_buffer_timeout,
      tls_v1: false,
      snappy: false,
      deflate: false,
      sample_rate: 0,
      user_agent: config.user_agent || @user_agent,
      msg_timeout: config.msg_timeout
    }
  end

  @spec now :: integer
  defp now do
    {megasec, sec, microsec} = :os.timestamp
    1_000_000 * megasec + sec + microsec / 1_000_000
  end

  @spec reset_connects(conn_state) :: conn_state
  defp reset_connects(state), do: %{state | connect_attempts: 0}

  @spec received_message(conn_state) :: conn_state
  defp received_message(state) do
    ConnInfo.update state, fn(info) ->
      %{info |
        rdy_count: info.rdy_count - 1,
        messages_in_flight: info.messages_in_flight + 1,
        last_msg_timestamp: now
      }
    end
    state
  end

  @spec update_rdy_count(conn_state, integer) :: conn_state
  defp update_rdy_count(state, rdy_count) do
    ConnInfo.update(state, %{rdy_count: rdy_count, last_rdy: rdy_count})
    state
  end

  @spec send_data_and_queue_resp(conn_state, tuple, {reference, pid}, atom) ::
    conn_state
  defp send_data_and_queue_resp(state, cmd, from, kind) do
    state.socket |> Socket.Stream.send!(encode(cmd))
    if kind == :noresponse do
      state
    else
      %{state |
        cmd_resp_queue: :queue.in({cmd, from, kind}, state.cmd_resp_queue)
      }
    end
  end

  @spec flush_cmd_queue(conn_state) :: conn_state
  defp flush_cmd_queue(state) do
    {item, new_queue} = :queue.out(state.cmd_queue)
    case item do
      {:value, {cmd, from, kind}} ->
        state = send_data_and_queue_resp(state, cmd, from, kind)
        flush_cmd_queue(%{state | cmd_queue: new_queue})
      :empty ->
        %{state | cmd_queue: new_queue}
    end
  end

  @spec start_receiving_messages(pid, conn_state) :: {:ok, conn_state}
  defp start_receiving_messages(socket, state) do
    reader_pid = spawn_link(
      __MODULE__,
      :recv_nsq_messages,
      [socket, self, state.config.read_timeout]
    )
    state = %{state | reader_pid: reader_pid}
    GenServer.cast(self, :flush_cmd_queue)
    {:ok, state}
  end

  @spec update_state_from_cmd(tuple, conn_state) :: conn_state
  defp update_state_from_cmd(cmd, state) do
    case cmd do
      {:rdy, count} -> update_rdy_count(state, count)
      _any -> state
    end
  end

  @spec init_conn_info(conn_state) :: any
  defp init_conn_info(state) do
    ConnInfo.update state, %{
      max_rdy: state.max_rdy,
      rdy_count: 0,
      last_rdy: 0,
      messages_in_flight: 0,
      last_msg_timestamp: now,
      retry_rdy_pid: nil,
      finished_count: 0,
      requeued_count: 0,
      failed_count: 0,
      backoff_count: 0,
    }
  end

  @spec wait_for_zero_in_flight(pid, binary) :: any
  defp wait_for_zero_in_flight(agent_pid, conn_id) do
    [in_flight] = ConnInfo.fetch(agent_pid, conn_id, [:messages_in_flight])
    Logger.debug("Conn #{inspect conn_id}: #{in_flight} still in flight")
    if in_flight <= 0 do
      :ok
    else
      :timer.sleep(1000)
      wait_for_zero_in_flight(agent_pid, conn_id)
    end
  end

  @spec wait_for_zero_in_flight_with_timeout(pid, binary, integer) :: any
  defp wait_for_zero_in_flight_with_timeout(agent_pid, conn_id, timeout) do
    try do
      Task.async(fn -> wait_for_zero_in_flight(agent_pid, conn_id) end)
        |> Task.await(timeout)
    catch
      :timeout, _ -> :timeout
    end
  end
end
