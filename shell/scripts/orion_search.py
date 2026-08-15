#!/usr/bin/env python3
"""Web search and page-reading helpers for the Orion AI assistant.

Both entry points are driven by tool calls the language model emits, so the
URL is never trusted input. Everything goes through fetch_url(), which:

  * allows only http and https -- urlopen also speaks file: and ftp:, so an
    unrestricted --url could read /etc/passwd or a private key and hand the
    contents back into the conversation;
  * refuses loopback, link-local, private and reserved addresses, which would
    otherwise make this an SSRF probe against anything bound on the machine;
  * re-applies both checks on every redirect hop, since a public URL can
    redirect to 127.0.0.1.
"""

import argparse
import ipaddress
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
TIMEOUT = 15
MAX_BYTES = 2 * 1024 * 1024
ALLOWED_SCHEMES = {"http", "https"}


class UnsafeUrlError(ValueError):
    """Raised when a URL is not a publicly routable http(s) target."""


def _assert_public_ip(host: str) -> None:
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as exc:
        raise UnsafeUrlError(f"could not resolve host {host!r}") from exc

    for info in infos:
        addr = ipaddress.ip_address(info[4][0])
        if (addr.is_loopback or addr.is_private or addr.is_link_local
                or addr.is_multicast or addr.is_reserved or addr.is_unspecified):
            raise UnsafeUrlError(
                f"host {host!r} resolves to non-public address {addr}"
            )


def assert_safe_url(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme.lower() not in ALLOWED_SCHEMES:
        raise UnsafeUrlError(
            f"scheme {parsed.scheme!r} is not allowed (only http and https)"
        )
    if not parsed.hostname:
        raise UnsafeUrlError("URL has no host")
    _assert_public_ip(parsed.hostname)
    return url


class _SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Validate every redirect target, not just the URL we were given."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        assert_safe_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_opener = urllib.request.build_opener(_SafeRedirectHandler)


def fetch_url(url: str) -> str:
    assert_safe_url(url)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with _opener.open(req, timeout=TIMEOUT) as resp:
        raw = resp.read(MAX_BYTES)
    return raw.decode("utf-8", errors="ignore")


class _VisibleTextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self._skip_tags = {"script", "style", "nav", "footer", "header", "aside"}
        self._skip_depth = 0
        self._in_body = False
        self._chunks = []

    def handle_starttag(self, tag, attrs):
        t = tag.lower()
        if t == "body":
            self._in_body = True
        if t in self._skip_tags:
            self._skip_depth += 1

    def handle_endtag(self, tag):
        t = tag.lower()
        if t in self._skip_tags and self._skip_depth > 0:
            self._skip_depth -= 1
        if t == "body":
            self._in_body = False

    def handle_data(self, data):
        if self._skip_depth == 0:
            # Prefer body content when present; fall back to full document text otherwise.
            if self._in_body or not self._chunks:
                self._chunks.append(data)

    def get_text(self):
        return " ".join(self._chunks)


class _DuckDuckGoResultParser(HTMLParser):
    """Extract result titles, URLs and snippets from the DDG HTML endpoint.

    Previously this was four re.findall patterns plus a re.sub tag stripper.
    Parsing HTML with regexes is what the code-scanning alert was about, and
    only read_webpage() was converted at the time.
    """

    def __init__(self):
        super().__init__()
        self.results: list[dict] = []
        self._current: dict | None = None
        self._capture: str | None = None

    @staticmethod
    def _classes(attrs) -> set:
        for name, value in attrs:
            if name == "class" and value:
                return set(value.split())
        return set()

    @staticmethod
    def _href(attrs) -> str:
        for name, value in attrs:
            if name == "href" and value:
                return value
        return ""

    def handle_starttag(self, tag, attrs):
        if tag != "a":
            return
        classes = self._classes(attrs)
        if "result__a" in classes or "result__url" in classes:
            if self._current is None:
                self._current = {"title": "", "url": "", "snippet": ""}
            if not self._current["url"]:
                self._current["url"] = self._href(attrs)
            self._capture = "title" if "result__a" in classes else None
        elif any(c.startswith("result__snippet") for c in classes):
            if self._current is None:
                self._current = {"title": "", "url": "", "snippet": ""}
            self._capture = "snippet"

    def handle_endtag(self, tag):
        if tag != "a":
            return
        if self._capture == "snippet" and self._current is not None:
            self.results.append(self._current)
            self._current = None
        self._capture = None

    def handle_data(self, data):
        if self._capture and self._current is not None:
            self._current[self._capture] += data

    def close(self):
        super().close()
        if self._current is not None and self._current.get("title"):
            self.results.append(self._current)
            self._current = None


def _resolve_ddg_url(raw: str) -> str:
    """DDG wraps outbound links in a redirect carrying the real URL in uddg.

    Normalise the protocol-relative form *before* unwrapping. Checking for a
    leading "//" first meant "//duckduckgo.com/l/?uddg=..." never reached the
    unwrap branch, so callers got the redirector instead of the destination.
    """
    if raw.startswith("//"):
        raw = "https:" + raw
    if "uddg=" in raw:
        try:
            params = urllib.parse.parse_qs(urllib.parse.urlparse(raw).query)
            if params.get("uddg"):
                return params["uddg"][0]
        except ValueError:
            pass
    return raw


def search_web(query, page_num):
    try:
        url = "https://html.duckduckgo.com/html/?q=" + urllib.parse.quote(query)
        html = fetch_url(url)

        parser = _DuckDuckGoResultParser()
        parser.feed(html)
        parser.close()

        start_idx = (page_num - 1) * 5
        entries = parser.results[start_idx:start_idx + 5]

        results = []
        for entry in entries:
            title = " ".join(entry["title"].split())
            snippet = " ".join(entry["snippet"].split())
            target = _resolve_ddg_url(entry["url"]).strip()
            if target and not target.startswith(("http://", "https://")):
                target = "https://" + target
            if title and target:
                results.append(f"Title: {title}\nURL: {target}\nSnippet: {snippet}")

        if not results:
            return "No useful results found for this page."

        return "\n\n".join(results)
    except UnsafeUrlError as e:
        return f"Refused unsafe search URL: {e}"
    except (urllib.error.URLError, OSError, ValueError) as e:
        return f"Error during web search: {e}"


def read_webpage(url):
    try:
        html = fetch_url(url)

        # Parse HTML safely and extract visible text while skipping non-content sections.
        extractor = _VisibleTextExtractor()
        extractor.feed(html)
        extractor.close()

        text = " ".join(extractor.get_text().split())

        if len(text) > 10000:
            text = text[:10000] + "\n\n[Content truncated due to length]"

        return text if text else "Could not extract text from this page."
    except UnsafeUrlError as e:
        return f"Refused to read this URL: {e}"
    except (urllib.error.URLError, OSError, ValueError) as e:
        return f"Error reading webpage: {e}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["search", "read"], required=True)
    parser.add_argument("--query", type=str, help="Search query")
    parser.add_argument("--page", type=int, default=1, help="Page number (1-indexed)")
    parser.add_argument("--url", type=str, help="URL to read")

    args = parser.parse_args()

    if args.mode == "search":
        if not args.query:
            print("Error: --query is required for search mode")
            return 1
        print(search_web(args.query, max(1, args.page)))
    else:
        if not args.url:
            print("Error: --url is required for read mode")
            return 1
        print(read_webpage(args.url))
    return 0


if __name__ == "__main__":
    sys.exit(main())
