defmodule SymphonyElixir.PromptBuilderTest do
  use SymphonyElixir.TestSupport

  describe "to_solid_value/to_solid_map normalization" do
    test "preserves scalar types (integer, float, boolean, nil) unchanged" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "n={{ issue.priority }} ok={{ issue.assigned_to_worker }}"
      )

      issue = %Issue{
        identifier: "T-1",
        title: "Scalars",
        description: nil,
        state: "Todo",
        url: "https://example.org/T-1",
        labels: [],
        priority: 4,
        assigned_to_worker: true
      }

      prompt = PromptBuilder.build_prompt(issue)

      assert prompt =~ "n=4"
      assert prompt =~ "ok=true"
    end

    test "renders nil field as empty string" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "desc=[{{ issue.description }}]"
      )

      issue = %Issue{
        identifier: "T-2",
        title: "Nil field",
        description: nil,
        state: "Todo",
        url: "https://example.org/T-2",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue)

      assert prompt == "desc=[]"
    end

    test "converts atom map keys to strings" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "id={{ issue.identifier }}"
      )

      issue = %Issue{
        identifier: "T-3",
        title: "Atom keys",
        description: "test",
        state: "Todo",
        url: "https://example.org/T-3",
        labels: []
      }

      # Map.from_struct produces atom keys; to_solid_map must stringify them
      prompt = PromptBuilder.build_prompt(issue)
      assert prompt == "id=T-3"
    end

    test "handles empty labels list" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "labels=[{{ issue.labels }}]"
      )

      issue = %Issue{
        identifier: "T-4",
        title: "Empty labels",
        description: "test",
        state: "Todo",
        url: "https://example.org/T-4",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue)
      assert prompt == "labels=[]"
    end

    test "renders multiple labels" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "labels={{ issue.labels }}"
      )

      issue = %Issue{
        identifier: "T-5",
        title: "Multi labels",
        description: "test",
        state: "Todo",
        url: "https://example.org/T-5",
        labels: ["bug", "urgent", "backend"]
      }

      prompt = PromptBuilder.build_prompt(issue)
      assert prompt =~ "bug"
      assert prompt =~ "urgent"
      assert prompt =~ "backend"
    end
  end

  describe "template rendering with Liquid features" do
    test "renders with upcase filter" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "{{ issue.identifier | upcase }}"
      )

      issue = %Issue{
        identifier: "t-6",
        title: "Filter",
        description: "test",
        state: "Todo",
        url: "https://example.org/t-6",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue)
      assert prompt == "T-6"
    end

    test "renders with downcase filter" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "{{ issue.state | downcase }}"
      )

      issue = %Issue{
        identifier: "T-7",
        title: "Filter",
        description: "test",
        state: "In Progress",
        url: "https://example.org/T-7",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue)
      assert prompt == "in progress"
    end

    test "renders conditional blocks" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "{% if issue.description %}Has desc{% else %}No desc{% endif %}"
      )

      with_desc = %Issue{
        identifier: "T-8",
        title: "Cond",
        description: "something",
        state: "Todo",
        url: "https://example.org/T-8",
        labels: []
      }

      without_desc = %Issue{
        identifier: "T-9",
        title: "Cond",
        description: nil,
        state: "Todo",
        url: "https://example.org/T-9",
        labels: []
      }

      assert PromptBuilder.build_prompt(with_desc) == "Has desc"
      assert PromptBuilder.build_prompt(without_desc) == "No desc"
    end

    test "renders for loop over labels" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "{% for label in issue.labels %}[{{ label }}]{% endfor %}"
      )

      issue = %Issue{
        identifier: "T-10",
        title: "Loop",
        description: "test",
        state: "Todo",
        url: "https://example.org/T-10",
        labels: ["a", "b", "c"]
      }

      prompt = PromptBuilder.build_prompt(issue)
      assert prompt == "[a][b][c]"
    end

    test "special characters in variable values pass through unescaped" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "title={{ issue.title }}"
      )

      issue = %Issue{
        identifier: "T-11",
        title: "Fix <script> & \"quotes\"",
        description: "test",
        state: "Todo",
        url: "https://example.org/T-11",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue)
      assert prompt == "title=Fix <script> & \"quotes\""
    end
  end

  describe "attempt parameter" do
    test "attempt is nil when not provided" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "attempt={{ attempt }}"
      )

      issue = %Issue{
        identifier: "T-12",
        title: "No attempt",
        description: "test",
        state: "Todo",
        url: "https://example.org/T-12",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue)
      assert prompt == "attempt="
    end

    test "attempt value renders when provided" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "attempt={{ attempt }}"
      )

      issue = %Issue{
        identifier: "T-13",
        title: "With attempt",
        description: "test",
        state: "Todo",
        url: "https://example.org/T-13",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 5)
      assert prompt == "attempt=5"
    end
  end

  describe "error handling" do
    test "raises on unknown filter with strict_filters" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "{{ issue.title | nonexistent_filter }}"
      )

      issue = %Issue{
        identifier: "T-14",
        title: "Bad filter",
        description: "test",
        state: "Todo",
        url: "https://example.org/T-14",
        labels: []
      }

      assert_raise Solid.RenderError, fn ->
        PromptBuilder.build_prompt(issue)
      end
    end

    test "raises on unclosed tag" do
      write_workflow_file!(Workflow.workflow_file_path(),
        prompt: "{% for label in issue.labels %}"
      )

      issue = %Issue{
        identifier: "T-15",
        title: "Unclosed",
        description: "test",
        state: "Todo",
        url: "https://example.org/T-15",
        labels: []
      }

      assert_raise RuntimeError, ~r/template_parse_error:/, fn ->
        PromptBuilder.build_prompt(issue)
      end
    end
  end
end
