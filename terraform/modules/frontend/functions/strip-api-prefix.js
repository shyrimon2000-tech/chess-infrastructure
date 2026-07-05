function handler(event) {
    var request = event.request;
    var uri = request.uri;

    // Mirrors nginx's per-route rewrite-target behavior (see
    // helm/chess-chart/templates/{main,game}-ingress.yaml, nginx branch):
    // each route's capture group starts at a different point, so the
    // prefix consumed here differs per route — this is NOT a uniform
    // "/api" strip.
    if (uri.indexOf('/api/rooms') === 0) {
        var roomsRest = uri.substring('/api/rooms'.length);
        request.uri = roomsRest === '' ? '/' : roomsRest;
    } else if (uri.indexOf('/api/game') === 0) {
        var gameRest = uri.substring('/api/game'.length);
        request.uri = gameRest === '' ? '/' : gameRest;
    } else if (uri.indexOf('/api') === 0) {
        var authRest = uri.substring('/api'.length);
        request.uri = authRest === '' ? '/' : authRest;
    }

    return request;
}
