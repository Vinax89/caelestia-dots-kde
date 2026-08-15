#!/usr/bin/env python3
import sys
import argparse
import urllib.request
import urllib.parse
import re
from html.parser import HTMLParser

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

def search_web(query, page_num):
    try:
        url = f"https://html.duckduckgo.com/html/?q={urllib.parse.quote(query)}"
        req = urllib.request.Request(
            url,
            headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'}
        )
        html = urllib.request.urlopen(req, timeout=15).read().decode('utf-8', errors='ignore')
        
        titles = re.findall(r'<h2 class="result__title">\s*<a[^>]*>(.*?)</a>', html, re.IGNORECASE | re.DOTALL)
        urls = re.findall(r'<a[^>]*class="result__url"[^>]*href="([^"]+)"', html, re.IGNORECASE | re.DOTALL)
        snippets = re.findall(r'<a[^>]*class="result__snippet[^>]*>(.*?)</a>', html, re.IGNORECASE | re.DOTALL)
        
        results = []
        
        parsed_urls = []
        for u in urls:
            if u.startswith('//'):
                parsed_urls.append("https:" + u)
            elif 'uddg=' in u:
                try:
                    parsed = urllib.parse.parse_qs(urllib.parse.urlparse(u).query)
                    if 'uddg' in parsed:
                        parsed_urls.append(parsed['uddg'][0])
                    else:
                        parsed_urls.append(u)
                except:
                    parsed_urls.append(u)
            else:
                parsed_urls.append(u)
                
        def strip_tags(text):
            return re.sub(r'<[^>]+>', '', text).strip()
            
        start_idx = (page_num - 1) * 5
        end_idx = start_idx + 5
        
        for i in range(min(len(titles), len(snippets), len(parsed_urls))):
            if i < start_idx: continue
            if i >= end_idx: break
            
            title = strip_tags(titles[i])
            snippet = strip_tags(snippets[i])
            u = parsed_urls[i]
            
            if not u.startswith("http"):
                u = "https://" + u
                
            if title and u:
                results.append(f"Title: {title}\nURL: {u}\nSnippet: {snippet}")
                
        if not results:
            return "No useful results found for this page."
            
        return "\n\n".join(results)
    except Exception as e:
        return f"Error during web search: {str(e)}"

def read_webpage(url):
    try:
        req = urllib.request.Request(
            url,
            headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'}
        )
        html = urllib.request.urlopen(req, timeout=15).read().decode('utf-8', errors='ignore')

        # Parse HTML safely and extract visible text while skipping non-content sections.
        extractor = _VisibleTextExtractor()
        extractor.feed(html)
        extractor.close()

        text = extractor.get_text()
        # Collapse whitespace
        text = re.sub(r'\s+', ' ', text).strip()
        
        if len(text) > 10000:
            text = text[:10000] + "\n\n[Content truncated due to length]"
            
        return text if text else "Could not extract text from this page."
    except Exception as e:
        return f"Error reading webpage: {str(e)}"

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["search", "read"], required=True)
    parser.add_argument("--query", type=str, help="Search query")
    parser.add_argument("--page", type=int, default=1, help="Page number (1-indexed)")
    parser.add_argument("--url", type=str, help="URL to read")
    
    args = parser.parse_args()
    
    if args.mode == "search":
        if not args.query:
            print("Error: --query is required for search mode")
            sys.exit(1)
        print(search_web(args.query, args.page))
    elif args.mode == "read":
        if not args.url:
            print("Error: --url is required for read mode")
            sys.exit(1)
        print(read_webpage(args.url))
