const APPLE_TEAM_ID = "V65NR77D7S";
const BUNDLE_ID = "de.goldkunibert.BetterBahn";

export default {
    async fetch(request) {
        const url = new URL(request.url);
        if (url.pathname === "/.well-known/apple-app-site-association") {
            const association = {
                applinks: {
                    apps: [],
                    details: [{
                        appID: `${APPLE_TEAM_ID}.${BUNDLE_ID}`,
                        paths: ["/oauth/traewelling/callback"],
                    }],
                },
            };
            return new Response(JSON.stringify(association), {
                status: 200,
                headers: {
                    "Content-Type": "application/json",
                    "Cache-Control": "public, max-age=300",
                },
            });
        }
        return handleTraewellingCallback(request) ?? new Response("Not Found", { status: 404 });
    },
};

// null means the request is for a different route.
export function handleTraewellingCallback(request) {
    const url = new URL(request.url);
    if (url.pathname !== "/oauth/traewelling/callback") return null;

    const headers = {
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "Content-Type": "text/plain; charset=utf-8",
    };
    if (request.method !== "GET") {
        return new Response("Method not allowed", {
            status: 405,
            headers: { ...headers, Allow: "GET" },
        });
    }

    const parameters = url.searchParams;
    const allowed = ["code", "state", "error", "error_description", "error_uri"];
    const duplicated = allowed.some(name => parameters.getAll(name).length > 1);
    const code = parameters.get("code");
    const error = parameters.get("error");
    if (duplicated || !parameters.get("state") || Boolean(code) === Boolean(error)) {
        return new Response("Missing or invalid OAuth response. Start login in BetterBahn.", {
            status: 400,
            headers,
        });
    }

    // Fixed destination: never accept a user-supplied redirect target.
    // PKCE verification and state validation remain in the app.
    const callback = new URL("betterbahn://oauth");
    for (const name of allowed) {
        const value = parameters.get(name);
        if (value !== null) callback.searchParams.set(name, value);
    }
    return new Response(null, {
        status: 302,
        headers: { ...headers, Location: callback.href },
    });
}
