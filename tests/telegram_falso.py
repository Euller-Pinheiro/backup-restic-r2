#!/usr/bin/env python3
"""Servidor HTTP falso da API do Telegram, só para os testes.

Uso: telegram_falso.py <arquivo-porta> <arquivo-pedidos>

Escuta em 127.0.0.1 numa porta livre (escrita em <arquivo-porta>) e grava cada
pedido recebido como uma linha JSON em <arquivo-pedidos>:
    {"caminho": "/bot<token>/sendMessage", "chat_id": "...", "text": "..."}
Responde como o Telegram responderia a um sendMessage bem-sucedido.
"""
import http.server
import json
import sys
from urllib.parse import parse_qs


class Telegram(http.server.BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        tamanho = int(self.headers.get("Content-Length", 0))
        corpo = parse_qs(self.rfile.read(tamanho).decode("utf-8"))
        pedido = {"caminho": self.path}
        pedido.update({chave: valores[0] for chave, valores in corpo.items()})
        with open(sys.argv[2], "a", encoding="utf-8") as saida:
            saida.write(json.dumps(pedido, ensure_ascii=False) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true,"result":{}}')

    def log_message(self, *args: object) -> None:  # silencia o log padrão
        pass


servidor = http.server.HTTPServer(("127.0.0.1", 0), Telegram)
with open(sys.argv[1], "w", encoding="utf-8") as arquivo:
    arquivo.write(str(servidor.server_address[1]))
servidor.serve_forever()
