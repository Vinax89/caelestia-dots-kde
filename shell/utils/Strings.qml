pragma Singleton

import QtQuick
import Quickshell

Singleton {
    property var _regexCache: ({})

    function isRegex(s: string): bool {
        return /^\^.*\$$/.test(s);
    }

    // Escape a value for interpolation *inside* a single-quoted shell word,
    // i.e. the caller writes '...${Strings.shellSingleQuoteEscape(v)}...'
    // and supplies the surrounding quotes itself.
    //
    // RegionSelection.qml called this as `StringUtils.shellSingleQuoteEscape`,
    // and no singleton by that name has ever existed -- this file registers as
    // `Strings`. The binding threw a ReferenceError, the command never resolved,
    // and image region detection silently did nothing.
    //
    // Prefer passing values as positional arguments where you can; this exists
    // for the cases where the value has to sit inside a larger command string.
    function shellSingleQuoteEscape(value: string): string {
        return String(value).split("'").join("'\\''");
    }

    // Parse JSON that came from somewhere we do not control -- an HTTP response,
    // a subprocess's stdout, a file on disk -- and return `fallback` instead of
    // throwing when it is not JSON at all.
    //
    // A bare JSON.parse in a Requests.get callback or a StdioCollector handler
    // throws out of the signal handler on any non-JSON body: a captive portal's
    // login page, an API rate-limit notice, a 5xx error page, an empty response
    // from a tool that failed to start.
    function parseJson(text: string, fallback: var): var {
        if (!text)
            return fallback;
        try {
            return JSON.parse(text);
        } catch (e) {
            console.warn("Strings.parseJson: ignoring malformed JSON:", e);
            return fallback;
        }
    }

    function getRegex(pattern: string): var {
        let re = _regexCache[pattern];
        if (!re) {
            re = new RegExp(pattern);
            _regexCache[pattern] = re;
        }
        return re;
    }

    function testRegex(pattern: string, target: string): bool {
        if (!pattern || !target)
            return false;
        if (isRegex(pattern))
            return getRegex(pattern).test(target);
        return pattern === target;
    }

    function testRegexList(filterList: var, target: string): bool {
        if (!filterList || !target)
            return false;
        const arr = Array.from(filterList);
        for (let i = 0; i < arr.length; i++) {
            const filter = arr[i];
            if (isRegex(filter)) {
                if (getRegex(filter).test(target))
                    return true;
            } else if (filter === target) {
                return true;
            }
        }
        return false;
    }

    function findMatchingIndex(filterList: var, target: string): int {
        if (!filterList || !target)
            return -1;
        const arr = Array.from(filterList);
        for (let i = 0; i < arr.length; i++) {
            const filter = arr[i];
            if (isRegex(filter)) {
                if (getRegex(filter).test(target))
                    return i;
            } else if (filter === target) {
                return i;
            }
        }
        return -1;
    }
}
