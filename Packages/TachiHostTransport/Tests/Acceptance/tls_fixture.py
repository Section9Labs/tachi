"""Disposable, loopback-only TLS identity for the Swift host process lab."""
import ssl
import subprocess


def tls_identity(base):
    def openssl(*args):
        subprocess.run(["openssl", *args], cwd=base, check=True, capture_output=True)

    # Config files also work with the LibreSSL CLI shipped by macOS.
    (base / "ca.cnf").write_text(
        "[req]\ndistinguished_name=dn\nx509_extensions=ca\n[dn]\n"
        "[ca]\nbasicConstraints=critical,CA:TRUE,pathlen:0\n"
        "keyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n")
    (base / "server.ext").write_text(
        "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n")
    for issuer in ("ca", "unrelated"):
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-sha256",
                "-subj", f"/CN=Tachi lab {issuer}", "-config", "ca.cnf",
                "-out", f"{issuer}.pem", "-keyout", f"{issuer}.key")
        openssl("x509", "-in", f"{issuer}.pem", "-outform", "DER", "-out", f"{issuer}.der")
    openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj", "/CN=localhost",
            "-out", "server.csr", "-keyout", "server.key")
    openssl("x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "1",
            "-days", "1", "-sha256", "-extfile", "server.ext", "-out", "server.pem")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(base / "server.pem", base / "server.key")
    return context
