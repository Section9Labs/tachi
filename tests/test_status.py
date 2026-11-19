import json
import unittest
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from threading import Thread

from tachi.http import CoordinatorHandler


class StatusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), CoordinatorHandler)
        cls.thread = Thread(target=cls.server.serve_forever)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join()
        cls.server.server_close()

    def get(self, path):
        client = HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        self.addCleanup(client.close)
        client.request("GET", path)
        return client.getresponse()

    def test_status_contract(self):
        response = self.get("/v1/status")
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Content-Type"), "application/json")
        body = json.load(response)
        self.assertIs(type(body["protocolVersion"]), int)
        self.assertEqual(body, {"service": "tachi", "protocolVersion": 1, "status": "ready"})

    def test_unknown_route(self):
        response = self.get("/v1/status/unknown")
        self.assertEqual(response.status, 404)
        self.assertEqual(json.load(response), {"error": "not_found"})
