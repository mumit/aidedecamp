from types import SimpleNamespace

import pytest

from attune.hosted.model_gateway import (
    MAX_MESSAGE_CHARS,
    MAX_RESPONSE_CHARS,
    HostedModelGateway,
    validate_messages,
)


class Completions:
    def __init__(self, text="answer"):
        self.text = text
        self.calls = []

    def create(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content=self.text))]
        )


def gateway(text="answer"):
    completions = Completions(text)
    client = SimpleNamespace(
        chat=SimpleNamespace(completions=completions)
    )
    return HostedModelGateway(
        client, models={"classify": "small-model", "converse": "large-model"}
    ), completions


def messages(content="hello"):
    return [
        {"role": "system", "content": "fixed boundary"},
        {"role": "user", "content": content},
    ]


def test_gateway_selects_only_fixed_task_route_and_budget():
    instance, completions = gateway()
    assert instance.complete(task="classify", messages=messages()).text == "answer"
    assert completions.calls == [
        {
            "model": "small-model",
            "messages": messages(),
            "max_tokens": 256,
        }
    ]

    instance.complete(task="converse", messages=messages())
    assert completions.calls[-1]["model"] == "large-model"
    assert completions.calls[-1]["max_tokens"] == 1_200


@pytest.mark.parametrize(
    "task,value",
    [
        ("other", messages()),
        ([], messages()),
        ("converse", []),
        ("converse", [{"role": "user", "content": "no boundary"}]),
        ("converse", [{"role": [], "content": "bad"}]),
        ("converse", [{"role": "system", "content": ""}]),
        ("converse", [{"role": "system", "content": "ok", "model": "x"}]),
        ("converse", messages("x" * (MAX_MESSAGE_CHARS + 1))),
    ],
)
def test_gateway_rejects_caller_authority_and_invalid_budgets(task, value):
    with pytest.raises(ValueError):
        validate_messages(task=task, messages=value)


def test_gateway_rejects_invalid_configuration_and_provider_response():
    instance, _ = gateway("")
    with pytest.raises(RuntimeError, match="contract"):
        instance.complete(task="converse", messages=messages())

    instance, _ = gateway("x" * (MAX_RESPONSE_CHARS + 1))
    with pytest.raises(RuntimeError, match="contract"):
        instance.complete(task="converse", messages=messages())

    with pytest.raises(ValueError, match="routes"):
        HostedModelGateway(SimpleNamespace(), models={"converse": "model"})
    with pytest.raises(ValueError, match="route"):
        HostedModelGateway(
            SimpleNamespace(),
            models={"classify": "model?caller=authority", "converse": "model"},
        )
