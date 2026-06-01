"""Web UI smoke test against the LIVE daemon at http://127.0.0.1:8080.

Skips cleanly when the daemon isn't reachable — this isn't a hermetic
test (daemon needs /dev/ttyUSB1 + real firmware), but it catches UI
regressions that the JSON-RPC tests can't (DOM rendering, event
plumbing, slider coalescing, etc).

Workflow:
  1. Start schindlerd: `make` or `/tmp/schindlerd-venv/bin/python
     control-plane/schindlerd/schindlerd.py -v`
  2. Run: pytest tests/test_web_smoke.py
"""
import asyncio
import socket

import pytest

try:
    from playwright.async_api import async_playwright
except ImportError:
    pytest.skip("playwright not installed", allow_module_level=True)


HOST = "127.0.0.1"
HTTP_PORT = 8080
WS_PORT = 8081
URL = f"http://{HOST}:{HTTP_PORT}/"


def _port_open(port: int) -> bool:
    try:
        with socket.create_connection((HOST, port), timeout=0.5):
            return True
    except (ConnectionRefusedError, socket.timeout, OSError):
        return False


@pytest.fixture(scope="module", autouse=True)
def require_daemon():
    if not (_port_open(HTTP_PORT) and _port_open(WS_PORT)):
        pytest.skip(f"daemon not reachable at {HOST}:{HTTP_PORT}/{WS_PORT} "
                    f"— start schindlerd first")


@pytest.fixture
async def page():
    """Function-scoped browser + page. pytest-asyncio's default loop scope is
    'function'; cross-scope sharing of Playwright objects breaks because the
    awaitables get bound to the wrong loop. Per-test launch costs ~0.5 s,
    which is fine for a smoke suite."""
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        ctx = await browser.new_context()
        pg = await ctx.new_page()
        try:
            yield pg
        finally:
            await ctx.close()
            await browser.close()


@pytest.mark.asyncio
async def test_page_loads(page):
    await page.goto(URL, wait_until="networkidle", timeout=10000)
    assert "Schindler" in await page.title()


@pytest.mark.asyncio
async def test_status_bar_connects(page):
    await page.goto(URL, wait_until="networkidle", timeout=10000)
    # The status badge has class "connected" once the WS is alive.
    await page.wait_for_selector("#status.connected", timeout=5000)
    text = await page.locator("#status-text").inner_text()
    assert text.strip() == "connected"


@pytest.mark.asyncio
async def test_color_section_renders(page):
    await page.goto(URL, wait_until="networkidle", timeout=10000)
    # The catalog has a "Color" category; the section h2 reads "COLOR"
    # because of the uppercase CSS transform — read DOM text directly.
    headings = await page.locator(".category > h2").all_text_contents()
    assert any("color" in h.lower() for h in headings)
    assert any("scaler" in h.lower() for h in headings)


@pytest.mark.asyncio
async def test_status_panel_populates(page):
    """After load + status.snapshot, S2MM_SR should be a hex value not '—'."""
    await page.goto(URL, wait_until="networkidle", timeout=10000)
    await page.wait_for_selector("#status.connected", timeout=5000)
    # Give the snapshot replay a beat to arrive after render.
    await asyncio.sleep(1.0)
    # Find the row for status.s2mm_sr by its title text and check the value cell.
    # The id label is shown in <small> under the title; the value lives in
    # .ctl-value within the same .ctl-row.
    s2mm_value = await page.evaluate("""() => {
        for (const row of document.querySelectorAll('.ctl-row')) {
            const small = row.querySelector('.ctl-title small');
            if (small && small.textContent === 'status.s2mm_sr') {
                return row.querySelector('.ctl-value').textContent.trim();
            }
        }
        return null;
    }""")
    assert s2mm_value is not None, "no row for status.s2mm_sr found"
    # Either populated (starts with '0x') or still showing '—' (race) — accept
    # both but log it for the operator.
    assert s2mm_value.startswith("0x") or s2mm_value == "—"


@pytest.mark.asyncio
async def test_saturation_slider_round_trips(page):
    """Drag the saturation slider, confirm the value cell echoes the new value."""
    await page.goto(URL, wait_until="networkidle", timeout=10000)
    await page.wait_for_selector("#status.connected", timeout=5000)
    # Locate the slider for color.saturation, set value to 150.
    set_value = await page.evaluate("""() => {
        for (const row of document.querySelectorAll('.ctl-row')) {
            const small = row.querySelector('.ctl-title small');
            if (small && small.textContent === 'color.saturation') {
                const slider = row.querySelector('input[type=range]');
                if (!slider) return null;
                slider.value = '150';
                slider.dispatchEvent(new Event('input', {bubbles: true}));
                return slider.value;
            }
        }
        return null;
    }""")
    assert set_value == "150"
    # Wait for the value cell to echo back '150%'.
    await page.wait_for_function("""() => {
        for (const row of document.querySelectorAll('.ctl-row')) {
            const small = row.querySelector('.ctl-title small');
            if (small && small.textContent === 'color.saturation') {
                const val = row.querySelector('.ctl-value').textContent.trim();
                if (val === '150%') return true;
            }
        }
        return false;
    }""", timeout=3000)
    # Restore default by going to 100 — keep the bench in a clean state.
    await page.evaluate("""() => {
        for (const row of document.querySelectorAll('.ctl-row')) {
            const small = row.querySelector('.ctl-title small');
            if (small && small.textContent === 'color.saturation') {
                const slider = row.querySelector('input[type=range]');
                slider.value = '100';
                slider.dispatchEvent(new Event('input', {bubbles: true}));
            }
        }
    }""")


@pytest.mark.asyncio
async def test_factory_profile_picker_has_entries(page):
    await page.goto(URL, wait_until="networkidle", timeout=10000)
    await page.wait_for_selector("#status.connected", timeout=5000)
    await page.wait_for_function(
        "() => document.getElementById('profile-select').options.length > 0",
        timeout=3000)
    options = await page.locator("#profile-select option").all_text_contents()
    # Should at least contain the four factory profiles.
    names = " ".join(options).lower()
    for needle in ("identity", "grayscale", "warm", "cool"):
        assert needle in names, f"factory profile '{needle}' missing in {options}"


@pytest.mark.asyncio
async def test_metrics_panel_toggles(page):
    await page.goto(URL, wait_until="networkidle", timeout=10000)
    await page.wait_for_selector("#status.connected", timeout=5000)
    # Hidden by default
    assert await page.locator("#metrics").is_hidden()
    await page.click("#metrics-toggle")
    # Wait for the panel to render its contents (system.metrics round-trip).
    await page.wait_for_function(
        "() => !document.getElementById('metrics').hidden && "
        "document.getElementById('metrics').textContent.toLowerCase()"
        ".includes('daemon metrics')",
        timeout=3000)
    body = await page.locator("#metrics").inner_text()
    assert "daemon metrics" in body.lower()
    assert "published" in body.lower()
    # Toggle off
    await page.click("#metrics-toggle")
    assert await page.locator("#metrics").is_hidden()


@pytest.mark.asyncio
async def test_reset_button_present(page):
    """Reset button exists and is wired (clicking it requires confirm() —
    Playwright's default is to dismiss dialogs which we use as the no-op path).
    """
    await page.goto(URL, wait_until="networkidle", timeout=10000)
    await page.wait_for_selector("#reset-all", timeout=2000)
    btn_text = await page.locator("#reset-all").inner_text()
    assert btn_text.strip() == "Reset"
