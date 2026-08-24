pragma Singleton

import QtQuick
import Quickshell

Singleton {
    property var _regexCache: ({})

    readonly property bool useAmericanEnglish: {
        const localeName = (Qt.locale().name || "").replace("-", "_");
        return localeName.startsWith("en_US");
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

    function localizeEnglishSpelling(text: string): string {
        if (!text || text.length === 0)
            return text;

        const rules = useAmericanEnglish
            ? [
                ["Colours", "Colors"],
                ["Colour", "Color"],
                ["colours", "colors"],
                ["colour", "color"],
                ["Recolour", "Recolor"],
                ["recolour", "recolor"],
                ["Favourites", "Favorites"],
                ["Favourite", "Favorite"],
                ["favourites", "favorites"],
                ["favourite", "favorite"],
                ["Behaviour", "Behavior"],
                ["behaviour", "behavior"]
            ]
            : [
                ["Colors", "Colours"],
                ["Color", "Colour"],
                ["colors", "colours"],
                ["color", "colour"],
                ["Recolor", "Recolour"],
                ["recolor", "recolour"],
                ["Favorites", "Favourites"],
                ["Favorite", "Favourite"],
                ["favorites", "favourites"],
                ["favorite", "favourite"],
                ["Behavior", "Behaviour"],
                ["behavior", "behaviour"]
            ];

        const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        let normalized = text;
        for (const [from, to] of rules)
            normalized = normalized.replace(new RegExp(`\\b${escapeRegExp(from)}\\b`, "g"), to);
        return normalized;
    }

    function testRegexList(filterList: list<string>, target: string): bool {
        const regexChecker = /^\^.*\$$/;
        for (const filter of filterList) {
            if (regexChecker.test(filter)) {
                let re = _regexCache[filter];
                if (!re) {
                    re = new RegExp(filter);
                    _regexCache[filter] = re;
                }
                if (re.test(target))
                    return true;
            } else {
                if (filter === target)
                    return true;
            }
        }
        return false;
    }
}
