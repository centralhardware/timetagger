"""
Test other stores.
"""

from _common import run_tests
from timetagger.app import stores


class Stub:
    def addEventListener(self, *args):
        pass

    def setTimeout(self, *args):
        pass

    def clearTimeout(self, *args):
        pass


stores.window = Stub()
stores.window.document = Stub()


if __name__ == "__main__":
    run_tests(globals())
