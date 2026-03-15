"""Tests for pagination limits in land_watch.py."""

import asyncio
import json
from unittest.mock import AsyncMock, patch

import land_watch


def test_get_paginated_list_stops_at_max_pages(capsys):
    """get_paginated_list stops after MAX_PAGINATION_PAGES even if batches keep coming."""
    call_count = 0

    async def fake_run_gh(*args):
        nonlocal call_count
        call_count += 1
        return json.dumps([{"id": call_count}])

    with patch.object(land_watch, "MAX_PAGINATION_PAGES", 3):
        with patch.object(land_watch, "run_gh", side_effect=fake_run_gh):
            result = asyncio.run(land_watch.get_paginated_list("/fake/endpoint"))

    assert len(result) == 3
    assert call_count == 3
    captured = capsys.readouterr()
    assert "pagination limit" in captured.out
    assert "/fake/endpoint" in captured.out


def test_get_paginated_list_normal_termination():
    """Normal pagination stops when an empty batch is returned (no warning)."""
    pages = [json.dumps([{"id": 1}]), json.dumps([{"id": 2}]), json.dumps([])]
    call_index = 0

    async def fake_run_gh(*args):
        nonlocal call_index
        data = pages[call_index]
        call_index += 1
        return data

    with patch.object(land_watch, "run_gh", side_effect=fake_run_gh):
        result = asyncio.run(land_watch.get_paginated_list("/fake/endpoint"))

    assert len(result) == 2
    assert call_index == 3


def test_get_reviews_stops_at_max_pages(capsys):
    """get_reviews stops after MAX_PAGINATION_PAGES."""
    call_count = 0

    async def fake_run_gh(*args):
        nonlocal call_count
        call_count += 1
        return json.dumps([{"id": call_count, "user": {"login": "u"}}])

    with patch.object(land_watch, "MAX_PAGINATION_PAGES", 2):
        with patch.object(land_watch, "run_gh", side_effect=fake_run_gh):
            result = asyncio.run(land_watch.get_reviews(42))

    assert len(result) == 2
    assert call_count == 2
    captured = capsys.readouterr()
    assert "pagination limit" in captured.out
    assert "PR #42" in captured.out


def test_get_check_runs_stops_at_max_pages(capsys):
    """get_check_runs stops after MAX_PAGINATION_PAGES."""
    call_count = 0

    async def fake_run_gh(*args):
        nonlocal call_count
        call_count += 1
        return json.dumps({"check_runs": [{"id": call_count}], "total_count": 99999})

    with patch.object(land_watch, "MAX_PAGINATION_PAGES", 2):
        with patch.object(land_watch, "run_gh", side_effect=fake_run_gh):
            result = asyncio.run(land_watch.get_check_runs("abc123"))

    assert len(result) == 2
    assert call_count == 2
    captured = capsys.readouterr()
    assert "pagination limit" in captured.out
    assert "abc123" in captured.out


def test_max_pagination_pages_constant():
    """MAX_PAGINATION_PAGES is set to 100."""
    assert land_watch.MAX_PAGINATION_PAGES == 100
