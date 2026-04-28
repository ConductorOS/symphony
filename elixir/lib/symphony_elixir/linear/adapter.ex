defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyCreateIssue($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        url
      }
    }
  }
  """

  @issue_context_query """
  query SymphonyIssueContext($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        id
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
      project {
        id
      }
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec create_issue(map()) :: {:ok, map()} | {:error, term()}
  def create_issue(%{source_issue_id: source_issue_id, title: title, description: description} = attrs)
      when is_binary(source_issue_id) and is_binary(title) and is_binary(description) do
    state_name = Map.get(attrs, :state_name, "Backlog")

    with {:ok, context} <- resolve_issue_context(source_issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@create_issue_mutation, %{input: issue_create_input(context, title, description)}),
         true <- get_in(response, ["data", "issueCreate", "success"]) == true,
         %{} = issue <- get_in(response, ["data", "issueCreate", "issue"]) do
      {:ok, issue}
    else
      false -> {:error, :issue_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp resolve_issue_context(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@issue_context_query, %{issueId: issue_id, stateName: state_name}),
         %{} = issue <- get_in(response, ["data", "issue"]),
         team_id when is_binary(team_id) <- get_in(issue, ["team", "id"]) do
      {:ok,
       %{
         team_id: team_id,
         project_id: get_in(issue, ["project", "id"]),
         state_id: get_in(issue, ["team", "states", "nodes", Access.at(0), "id"])
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_context_not_found}
    end
  end

  defp issue_create_input(context, title, description) do
    %{
      teamId: context.team_id,
      projectId: context.project_id,
      stateId: context.state_id,
      title: title,
      description: description
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
