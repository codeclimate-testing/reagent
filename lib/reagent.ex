#            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#                    Version 2, December 2004
#
#            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION
#
#  0. You just DO WHAT THE FUCK YOU WANT TO.

defmodule Reagent do
  @spec start(Keyword.t | [Keyword.t]) :: { :ok, pid } | { :error, term }
  def start(listeners) do
    start([], listeners)
  end

  @spec start(module, Keyword.t, Keyword.t | [Keyword.t]) :: { :ok, pid } | { :error, term }
  def start(module, options, listeners) do
    start(Keyword.merge(options, module: module), listeners)
  end

  @spec start(module | Keyword.t, Keyword.t | [Keyword.t]) :: { :ok, pid } | { :error, term }
  def start(module, listeners) when module |> is_atom do
    start([module: module], listeners)
  end

  def start(options, listeners) do
    :gen_server.start __MODULE__, [options, listeners], []
  end

  @spec start_link(Keyword.t | [Keyword.t]) :: { :ok, pid } | { :error, term }
  def start_link(listeners) do
    start_link([], listeners)
  end

  @spec start_link(module, Keyword.t, Keyword.t | [Keyword.t]) :: { :ok, pid } | { :error, term }
  def start_link(module, options, listeners) do
    start_link(Keyword.merge(options, module: module), listeners)
  end

  @spec start_link(module | Keyword.t, Keyword.t | [Keyword.t]) :: { :ok, pid } | { :error, term }
  def start_link(module, listeners) when module |> is_atom do
    start_link([module: module], listeners)
  end

  def start_link(options, listeners) do
    :gen_server.start_link __MODULE__, [options, listeners], []
  end

  def wait(timeout // :infinity) do
    receive do
      { Reagent, :ack } ->
        :ok
    after
      timeout ->
        { :timeout, timeout }
    end
  end

  use GenServer.Behaviour

  alias Reagent.Listener
  alias Reagent.Connection

  alias Data.Seq
  alias Data.Dict

  defrecord State, options: nil, listeners: HashDict.new, connections: HashDict.new, count: HashDict.new, waiting: HashDict.new

  def init([options, listeners]) do
    Process.flag :trap_exit, true

    if Seq.first(listeners) |> is_tuple do
      listeners = [listeners]
    end

    listeners = Seq.map listeners, &create(options, &1)
    error     = listeners |> Seq.find_value fn
      { :error, reason } ->
        { :stop, reason }

      { :ok, _ } ->
        false
    end

    if error do
      error
    else
      listeners = HashDict.new listeners, fn { :ok, listener } ->
        { listener.id, listener }
      end

      { :ok, State[options: options, listeners: listeners] }
    end
  end

  defp create(global, listener) do
    listener = Listener.new(Keyword.merge(global, listener))
    listener = listener.id(make_ref)
    listener = listener.pool(Process.self)

    if listener.module do
      socket = if listener.secure? do
        Socket.SSL.listen listener.port, listener.to_options
      else
        Socket.TCP.listen listener.port, listener.to_options
      end

      case socket do
        { :ok, socket } ->
          listener = listener.socket(socket)
          listener = listener.acceptors(Seq.map(1 .. listener.acceptors, fn _ ->
            listener.module.start_link(Process.self, listener)
          end))

          { :ok, listener }

        { :error, _ } = error ->
          error
      end
    else
      { :error, :no_module }
    end
  end

  def handle_cast({ :accepted, Connection[listener: Listener[id: id]] = conn, pid }, State[connections: connections, count: count] = state) do
    if Process.alive?(pid) do
      Process.link pid

      count       = count |> Dict.update(id, 0, &(&1 + 1))
      count       = count |> Dict.update(:total, 0, &(&1 + 1))
      connections = connections |> Dict.put(pid, conn)

      state = state.count(count)
      state = state.connections(connections)
    end

    { :noreply, state }
  end

  def handle_call({ :wait, Listener[] = listener }, from, State[options: options, count: listeners, waiting: waiting] = state) do
    if Keyword.has_key?(options, :max_connections) or Keyword.has_key?(listener.options, :max_connections) do
      total = listeners[:total] || 0
      count = listeners[listener.id] || 0

      cond do
        options[:max_connections] && total >= options[:max_connections] ->
          waiting = waiting |> Dict.update(listener.id, [], &[from | &1])

          { :noreply, state.waiting(waiting) }

        listener.options[:max_connections] && count >= listener.options[:max_connections] ->
          waiting = waiting |> Dict.update(listener.id, [], &[from | &1])

          { :noreply, state.waiting(waiting) }
      end
    else
      { :reply, :ok, state }
    end
  end

  def handle_call(:count, _from, State[count: listeners] = _state) do
    { :reply, Seq.reduce(listeners, 0, &(elem(&1, 1) + &2)), _state }
  end

  def handle_call({ :count, listener }, _from, State[count: listeners] = _state) do
    { :reply, listeners[listener.id] || 0, _state }
  end

  def handle_info({ :EXIT, pid, _reason }, State[listeners: listeners, connections: connections, waiting: waiting, count: count] = state) do
    if Connection[listener: Listener[id: id]] = connections |> Dict.get(pid) do
      count       = count |> Dict.update(id, &(&1 - 1))
      count       = count |> Dict.update(:total, &(&1 - 1))
      connections = connections |> Dict.delete(pid)

      case waiting[id] do
        [wait | rest] ->
          :gen_server.reply(wait, :ok)

          waiting = waiting |> Dict.put(id, rest)

        _ ->
          nil
      end

      state = state.count(count)
      state = state.connections(connections)
      state = state.waiting(waiting)
    end

    Enum.each listeners, fn { _, Listener[acceptors: acceptors] } ->
      Enum.each acceptors, fn acceptor ->
        if acceptor == pid do
          IO.puts "BIP BIP BIP"
        end
      end
    end

    { :noreply, state }
  end
end