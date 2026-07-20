import asyncio
import json
import logging
import time

logger = logging.getLogger("as11_collector")


class AS11Collector:
    def __init__(self, host='127.0.0.1', port=39011):
        self.host = host
        self.port = port
        self.reader = None
        self.writer = None
        self.connected = False

        self._req_id = 0
        self._pending_requests = {}
        self._watchdog_timeout = 5.0  # seconds without data
        self._last_data_time = 0

        self.running = False

        # Determine versions empirically
        self.method_versions = {}

    def _next_id(self):
        self._req_id += 1
        return self._req_id

    async def _send_request(self, method, params=None, version="2.0", timeout=5.0):
        if not self.connected or not self.writer:
            raise ConnectionError("Not connected to bridge")

        req_id = self._next_id()
        req = {
            "jsonrpc": version,
            "method": method,
            "id": req_id
        }
        if params is not None:
            req["params"] = params

        future = asyncio.get_running_loop().create_future()
        self._pending_requests[req_id] = future

        line = json.dumps(req) + "\n"
        self.writer.write(line.encode('utf-8'))
        await self.writer.drain()

        try:
            # Wait for response with timeout
            response = await asyncio.wait_for(future, timeout=timeout)
            return response
        finally:
            self._pending_requests.pop(req_id, None)

    async def call_method_empirically(self, method, params=None):
        """Try version 2.0, fallback to 1.0 if not known."""
        version = self.method_versions.get(method, "2.0")
        try:
            res = await self._send_request(method, params, version=version)
            self.method_versions[method] = version
            return res
        except Exception:
            if version == "2.0":
                logger.warning(f"Method {method} failed with 2.0, trying 1.0")
                res = await self._send_request(method, params, version="1.0")
                self.method_versions[method] = "1.0"
                return res
            raise

    async def _read_loop(self):
        try:
            while self.running and self.connected:
                line = await self.reader.readline()
                if not line:
                    logger.warning("EOF received from bridge")
                    break

                self._last_data_time = time.time()

                try:
                    data = json.loads(line.decode('utf-8').strip())
                except json.JSONDecodeError:
                    logger.error(f"Invalid JSON received: {line}")
                    continue

                msg_id = data.get('id')

                # If it has an ID, it's a response
                if msg_id is not None:
                    future = self._pending_requests.get(msg_id)
                    if future and not future.done():
                        if 'error' in data:
                            future.set_exception(Exception(f"RPC Error: {data['error']}"))
                        else:
                            future.set_result(data.get('result'))
                else:
                    # Notification / Stream sample
                    method = data.get('method')
                    if method == 'StreamSample':
                        self.handle_sample(data.get('params', {}))
                    else:
                        logger.info(f"Unhandled notification: {data}")

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Read loop error: {e}")
        finally:
            self.connected = False

    def handle_sample(self, sample):
        """Process a streamed sample (to be normalized into Postgres later)."""
        # For now, just log at debug so we don't spam the console too much,
        # but maybe print one out of 100 or something to prove it's working.
        if getattr(self, '_sample_count', 0) % 50 == 0:
            logger.info(f"Streamed Sample: {sample}")
        self._sample_count = getattr(self, '_sample_count', 0) + 1

    async def _watchdog_loop(self):
        try:
            while self.running and self.connected:
                await asyncio.sleep(1.0)
                time_since_data = time.time() - self._last_data_time
                if time_since_data > self._watchdog_timeout:
                    logger.error(f"Watchdog timeout! No data for {time_since_data:.1f}s. Disconnecting.")
                    self.connected = False
                    if self.writer:
                        self.writer.close()
        except asyncio.CancelledError:
            pass

    async def start(self):
        self.running = True
        backoff = 1.0
        max_backoff = 30.0

        while self.running:
            try:
                logger.info(f"Attempting connection to {self.host}:{self.port}...")
                self.reader, self.writer = await asyncio.open_connection(self.host, self.port)
                self.connected = True
                self._last_data_time = time.time()
                backoff = 1.0  # reset backoff

                logger.info("Connected!")

                # Start read and watchdog loops
                read_task = asyncio.create_task(self._read_loop())
                watchdog_task = asyncio.create_task(self._watchdog_loop())

                # Handshake
                ver = await self.call_method_empirically("GetVersion")
                logger.info(f"Bridge version: {ver}")

                dt = await self.call_method_empirically("GetDateTime")
                logger.info(f"Bridge datetime: {dt}")

                res = await self.call_method_empirically("StartStream")
                logger.info(f"StartStream response: {res}")

                # Wait for disconnect
                await read_task
                watchdog_task.cancel()

            except Exception as e:
                logger.error(f"Connection failed or interrupted: {e}")
            finally:
                self.connected = False
                if self.writer:
                    self.writer.close()
                    try:
                        await self.writer.wait_closed()
                    except Exception as exc:
                        logger.debug(f"Ignored error awaiting writer close: {exc}")

            if self.running:
                logger.info(f"Reconnecting in {backoff} seconds...")
                await asyncio.sleep(backoff)
                backoff = min(max_backoff, backoff * 2.0)

    async def stop(self):
        self.running = False
        self.connected = False
        if self.writer:
            self.writer.close()
            try:
                await self.writer.wait_closed()
            except Exception as exc:
                logger.debug(f"Ignored error awaiting writer close: {exc}")
