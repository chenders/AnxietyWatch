import asyncio
import json
import time
import random
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("mock_aircannect")


class MockAS11Bridge:
    def __init__(self, host='127.0.0.1', port=39011):
        self.host = host
        self.port = port
        self.server = None
        self.clients = set()

    async def start(self):
        self.server = await asyncio.start_server(self.handle_client, self.host, self.port)
        logger.info(f"Mock aircannect server listening on {self.host}:{self.port}")

    async def stop(self):
        if self.server:
            self.server.close()
            await self.server.wait_closed()

        # Also drop all existing connections
        for writer in list(self.clients):
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass
        self.clients.clear()

    async def handle_client(self, reader, writer):
        addr = writer.get_extra_info('peername')
        logger.info(f"Client connected: {addr}")
        self.clients.add(writer)

        streaming_task = None

        try:
            while True:
                line = await reader.readline()
                if not line:
                    logger.info(f"Client disconnected: {addr}")
                    break

                try:
                    req = json.loads(line.decode('utf-8').strip())
                    logger.info(f"Received from {addr}: {req}")
                except json.JSONDecodeError:
                    logger.warning(f"Invalid JSON from {addr}: {line}")
                    continue

                method = req.get('method')
                msg_id = req.get('id')
                version = req.get('jsonrpc', '2.0')

                if method == 'GetVersion':
                    resp = {
                        "jsonrpc": version,
                        "id": msg_id,
                        "result": {"version": "1.0.0-mock", "build": "test"}
                    }
                    writer.write((json.dumps(resp) + "\n").encode('utf-8'))
                    await writer.drain()

                elif method == 'GetDateTime':
                    resp = {
                        "jsonrpc": version,
                        "id": msg_id,
                        "result": {"datetime": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
                    }
                    writer.write((json.dumps(resp) + "\n").encode('utf-8'))
                    await writer.drain()

                elif method == 'StartStream':
                    resp = {
                        "jsonrpc": version,
                        "id": msg_id,
                        "result": {"status": "ok", "streaming": True}
                    }
                    writer.write((json.dumps(resp) + "\n").encode('utf-8'))
                    await writer.drain()

                    if streaming_task is None or streaming_task.done():
                        streaming_task = asyncio.create_task(self.stream_data(writer))
                else:
                    # Unknown method
                    if msg_id is not None:
                        resp = {
                            "jsonrpc": version,
                            "id": msg_id,
                            "error": {"code": -32601, "message": "Method not found"}
                        }
                        writer.write((json.dumps(resp) + "\n").encode('utf-8'))
                        await writer.drain()

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Error handling client {addr}: {e}")
        finally:
            if streaming_task:
                streaming_task.cancel()
            self.clients.discard(writer)
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def stream_data(self, writer):
        logger.info("Started streaming data to client")
        # Generate 25Hz flow/pressure, 1Hz spo2/hr/leak
        # We will loop at 25Hz (0.04s)

        cycle_count = 0
        try:
            while True:
                now_str = time.strftime('%Y-%m-%dT%H:%M:%S.%fZ', time.gmtime())

                # High frequency data (25 Hz)
                samples = []

                samples.append({
                    "channel": "flow",
                    "value": random.gauss(15.0, 2.0),
                    "unit": "L/min",
                    "ts_utc": now_str
                })
                samples.append({
                    "channel": "pressure",
                    "value": random.gauss(10.0, 0.5),
                    "unit": "cmH2O",
                    "ts_utc": now_str
                })

                # Low frequency data (1 Hz -> every 25 cycles)
                if cycle_count % 25 == 0:
                    samples.append({
                        "channel": "spo2",
                        "value": random.randint(95, 100),
                        "unit": "%",
                        "ts_utc": now_str
                    })
                    samples.append({
                        "channel": "hr",
                        "value": random.randint(60, 80),
                        "unit": "bpm",
                        "ts_utc": now_str
                    })
                    samples.append({
                        "channel": "leak",
                        "value": random.uniform(0.0, 5.0),
                        "unit": "L/min",
                        "ts_utc": now_str
                    })

                # Batch send notifications
                for sample in samples:
                    notification = {
                        "jsonrpc": "2.0",
                        "method": "StreamSample",
                        "params": sample
                    }
                    writer.write((json.dumps(notification) + "\n").encode('utf-8'))

                await writer.drain()
                cycle_count += 1
                await asyncio.sleep(0.04)
        except asyncio.CancelledError:
            logger.info("Streaming task cancelled")
        except Exception as e:
            logger.error(f"Streaming error: {e}")


async def main():
    server = MockAS11Bridge()
    await server.start()
    try:
        while True:
            await asyncio.sleep(3600)
    except KeyboardInterrupt:
        await server.stop()

if __name__ == '__main__':
    asyncio.run(main())
