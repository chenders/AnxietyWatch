from as11_collector import AS11Collector
from mock_aircannect import MockAS11Bridge
import asyncio
import logging
import sys
import os

# Add the server directory to python path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))


logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("test_aircannect_mock")


async def manual_integration_harness():
    # Start the mock bridge
    bridge = MockAS11Bridge(host='127.0.0.1', port=39011)
    await bridge.start()

    # Start the collector
    collector = AS11Collector(host='127.0.0.1', port=39011)
    collector_task = asyncio.create_task(collector.start())

    logger.info("Letting them communicate for 5 seconds...")
    await asyncio.sleep(5)

    logger.info("Stopping mock bridge to test reconnect logic...")
    await bridge.stop()

    logger.info("Waiting 3 seconds to see collector backoff/reconnect attempts...")
    await asyncio.sleep(3)

    logger.info("Restarting mock bridge...")
    await bridge.start()

    logger.info("Letting them communicate for another 5 seconds...")
    await asyncio.sleep(5)

    # Clean up
    await collector.stop()
    collector_task.cancel()
    await bridge.stop()
    logger.info("Test complete!")

if __name__ == '__main__':
    asyncio.run(manual_integration_harness())
