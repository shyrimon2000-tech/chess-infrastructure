function handler(event) {
    var request = event.request;

    if (request.uri.indexOf('/api') === 0) {
        var rest = request.uri.substring(4);
        request.uri = rest === '' ? '/' : rest;
    }

    return request;
}
