# Run as: iex --dot-iex path/to/notebook.exs

# Title: Slack Summarizer

Mix.install([
  {:slack, "~> 0.23.5"},
  {:httpoison, "~> 1.8"},
  {:poison, "~> 4.0"}
])

# ── Getting Channel Data and User Data from Slack ──

token = System.get_env("LB_SLACK_AUTH_TOKEN")
channel_id = System.get_env("LB_CHANNEL_ID")

defmodule SlackUtils do
  def fetch_users(token) do
    url = "https://slack.com/api/users.list"

    headers = [
      {"Authorization", "Bearer #{token}"}
    ]

    {:ok, users} =
      case HTTPoison.get(url, headers) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          {:ok, body |> Jason.decode!() |> Map.get("members", [])}

        {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
          {:error, "Received status code #{status_code}. Response: #{body}"}

        {:error, error} ->
          {:error, error}
      end

    Enum.into(users, %{}, fn user -> {Map.get(user, "id"), Map.get(user, "real_name")} end)
  end

  def fetch_slack_messages(token, channel_id) do
    options = [timeout: 60000, recv_timeout: 60000]

    {:ok, response} =
      HTTPoison.get(
        "https://slack.com/api/conversations.history?token=#{token}&channel=#{channel_id}&inclusive=true&limit=1000",
        [],
        options
      )

    messages = Poison.decode!(response.body)["messages"]
    Enum.map(messages, fn message -> fetch_thread_replies(token, channel_id, message) end)
  end

  def fetch_thread_replies(token, channel_id, %{"ts" => ts, "thread_ts" => thread_ts} = message)
      when thread_ts == ts do
    # This message is the parent message of a thread, fetch the replies
    {:ok, response} =
      HTTPoison.get(
        "https://slack.com/api/conversations.replies?token=#{token}&channel=#{channel_id}&thread_ts=#{thread_ts}"
      )

    replies = Poison.decode!(response.body)["messages"]
    # Combine the parent message with its replies
    [message | replies]
  end

  def fetch_thread_replies(_token, _channel_id, message) do
    # This message is not part of a thread or is a reply in a thread, return it as is
    message
  end
end

user_map = SlackUtils.fetch_users(token)

seven_days_ago = DateTime.add(DateTime.utc_now(), -7, :day) |> DateTime.to_unix()

url = "https://slack.com/api/conversations.history?channel=#{channel_id}&oldest=#{seven_days_ago}"

headers = [
  {"Authorization", "Bearer #{token}"}
]

{:ok, response} =
  case HTTPoison.get(url, headers) do
    {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
      {:ok, body |> Jason.decode!()}

    {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
      {:error, "Received status code #{status_code}. Response: #{body}"}

    {:error, error} ->
      {:error, error}
  end

# Get the 'messages' field from the response
messages = Map.get(response, "messages", [])

# Map over the messages and extract the 'text' field from each message
slack_messages =
  Enum.map(messages, fn message ->
    user_id = Map.get(message, "user", "")
    user_name = Map.get(user_map, user_id, user_id)

    case Map.get(message, "text") do
      nil ->
        # If 'text' field is not present, try to get it from 'blocks' -> 'elements' -> 'elements'
        blocks = Map.get(message, "blocks", [])
        elements = Enum.flat_map(blocks, &Map.get(&1, "elements", []))
        nested_elements = Enum.flat_map(elements, &Map.get(&1, "elements", []))
        message_text = Enum.join(Enum.map(nested_elements, &Map.get(&1, "text", "")), " ")

        message_text =
          Enum.reduce(user_map, message_text, fn {id, name}, acc ->
            String.replace(acc, "<@#{id}>", "@#{name}")
          end)

        "User #{user_name}: #{message_text}"

      text ->
        text =
          Enum.reduce(user_map, text, fn {id, name}, acc ->
            String.replace(acc, "<@#{id}>", "@#{name}")
          end)

        "User #{user_name}: #{text}"
    end
  end)

# ── Sending Data to Summarize ──

temperature = 0.7
max_tokens = 1000
api_key = System.get_env("LB_OPENAI_API_KEY")
# model = "text-davinci-003"
model = "gpt-4"

prompt =
  "You are an executive assistant to a CEO. The CEO has tasked you with going through the last 7 days of slack messages in a slack channel and summarizing any key decisions they should know about to make decisions about the business. The summary total should be about 300 words long.

Bellow is the list of slack messages sent in the last 7 days, formatted as `User <user_name>: <message_text>`"

end_prompt = "I want you to think step by step. 
First, you will need to read through the information and extract the most important themes. Please provide a list of these key themes before you start the detailed summary. Describe the themes in one sentence or less.

Second, I want you to summarize each of these themes. Be specific, and explain why this was an important detail to include in the summary. Focus particularly on decisions made, problems identified, and new ideas proposed. Where possible, identify the user's who contributed to the theme.

Key Themes:
"

url = "https://api.openai.com/v1/engines/text-davinci-003/completions"

headers = [
  {"Authorization", "Bearer #{api_key}"},
  {"Content-Type", "application/json"}
]

body =
  %{
    "prompt" => "#{prompt}\n---\n#{slack_messages}\n---\n#{end_prompt}",
    "max_tokens" => max_tokens,
    "temperature" => temperature
  }
  |> Jason.encode!()

# Set custom timeout
options = [timeout: 60000, recv_timeout: 60000]

{:ok, summary} =
  case HTTPoison.post(url, body, headers, options) do
    {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
      {:ok,
       body |> Jason.decode!() |> Map.get("choices", []) |> List.first() |> Map.get("text", "")}

    {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
      {:error, "Received status code #{status_code}. Response: #{body}"}

    {:error, error} ->
      {:error, error}
  end

IO.puts(summary)
