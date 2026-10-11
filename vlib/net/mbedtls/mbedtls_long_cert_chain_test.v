// vtest build: !(windows && tinyc) // TODO: fix these by adding declarations for the missing functions in the prebuilt tcc
module main

import net.mbedtls
import time

// mbedtls_long_cert_chain_test.v — a Certificate handshake message larger
// than 4 KB crosses in BOTH directions. mbedtls fragments application data
// into records of MBEDTLS_SSL_OUT_CONTENT_LEN, but it does NOT fragment an
// outgoing TLS handshake message: the whole Certificate message (the chain
// with its length prefixes) must fit the outgoing buffer, or the handshake
// fails with MBEDTLS_ERR_SSL_INTERNAL_ERROR ("Record too large"). The chain
// here is three RSA-4096 certificates (leaf + intermediate + root, 1,439 +
// 1,390 + 1,363 bytes DER, ~4.2 KB on the wire), the size of a commercial
// chain sent with its root; the peer trusts only the root, so the handshake
// also proves the intermediate arrived. It is the guard on the outgoing
// buffer size in thirdparty/mbedtls/include/mbedtls/mbedtls_config.h
// (cx-home/cx-platform-xap#20: 4096 fails this test, 8192 passes).

const long_chain_pem = '-----BEGIN CERTIFICATE-----\nMIIFmzCCA4OgAwIBAgIUGjqNo9U/NyGgsufBg2xbgEAuQ6kwDQYJKoZIhvcNAQEL\nBQAwPjELMAkGA1UEBhMCVVMxEDAOBgNVBAoMB2N4IHRlc3QxHTAbBgNVBAMMFGN4\nIHRlc3QgaW50ZXJtZWRpYXRlMCAXDTI2MTAxMTA3MDUxM1oYDzIxMjYwOTE3MDcw\nNTEzWjAzMQswCQYDVQQGEwJVUzEQMA4GA1UECgwHY3ggdGVzdDESMBAGA1UEAwwJ\nbG9jYWxob3N0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjTOQXjV7\nR5mpz+gFGWdzH6kCvXBt3QzrASYhVzNWVj2At+Rlz0iUgw4Dd2k8Z118G3vNh3VO\ncwk2fQZmtn531ma/W0pHed45DEzPbkKtS7iy9/61kxLFE4/bPe4tTXIaV23+odFa\nuAEOJEH2a75D8cMaiqbAw31HfBSz5l6esSkXvRYpziisLOtXppk4riF38VAee8nr\nBK/jczfn1vjpkztdv7RYintdSOpyKOWFZNavXDGn91/hAh9MAd3GyKdeKwQsA6IV\neBp8eEAyONulkITpU8Q3XYID/3aKBfNsGscGa5pN7IWiAXwXPqn2IedOm2JAc3et\nzX8OzLZ0KyDKhUCJrZFbQC1hTQC8dUF6HNHIbpEEoZ2OOEiiLcD19NkSPeaLLPBm\nJrKdnu5qiMU1C098RgA1LtSnzfiYZlcwBuDMqoJyrEb+S5wgQF3Kwo6xwgQ0yDHK\nDrwOHW0yKv5yLnO5JJqOtOpEWpP0VUyfRWjiMuomdpD8nnDGhSh9AJh52Sj8VUNj\ndSRBB547qPjuj+TkGHFo23DLb7YAkdT4+ymldLvebb2JTxs3lEmtJSLpR3cWjHVH\nmqoy9aahrYlmzxZuAH0oM5ruMy1t2YeSJCkUtjjmgKeQ11SUHzKEvq22IJ6YUHFN\n75HKHeudMvSwIiosNT6VC21NogJtgIu6qakCAwEAAaOBmTCBljAJBgNVHRMEAjAA\nMA4GA1UdDwEB/wQEAwIFoDAdBgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIw\nGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMB0GA1UdDgQWBBTopV7wIIrggHl7\n3VPTIgnCMnwbSjAfBgNVHSMEGDAWgBR6FH2ReRCItxhf/9YaGxeI59k1eTANBgkq\nhkiG9w0BAQsFAAOCAgEANrsJmPnHdHHOJ/Xhcr+kl0TdsjIu+5shLnofmb5DP0OM\niXtGOKpIm+m1spcbIkCHoCpf54erRRGPUC9QJJM9Z/ZbD9Ex1BluofxnaSAIgeh6\nvX1D1RAubLsoLYH+sGveFBJfLSiYL4wm0M2qkKtndwd/8ZhWJklK/seUKB9Ci3XY\nZ1TgtLL5pA/wfW88R1Nzc6Wn+XBs3tqAr8nHy2t7MC6qlEHzQm0mQkptdWFXbj/8\nbyVYOwfrWlo+zJ3uIEkHzInVoUU7AAAMZgZF7mNFfZcNJ9GZELZTy12HjYfXURyW\nYUm4z5zmc/RH5wdNESnqOFqpBLvt2TYSN6sxbquWPFjSc5gGEwkAm2ChqFhT/6Z7\nv1iKzrQNVxVVtgsdRZOOxnSztBm2/a/wkbacFlQc04nIWTNOsXAdYFblv42xScnE\nw9BFU+Ok3ghTA321pcyqstMz4YgfOcSDlmpOBoF2bSUgzY07FAm52SFt7fxTKkH/\nB13B27wsTIJSqYHE7xQZScUNOE+JNJnObYp5gZYdgTvtiwVt4apExf1TkGemL2kf\nQiY7k1LT2wkMMEzxj8MlooInDTxA1wx9QQHEU7vMRI9do70JuuY/stid6lJ0ASED\nM7UU7r0FFbAGxNtIxhREJWM1L3HADcHkKzJI+H/2L3DKkOWlz55HpsSpPukuMko=\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nMIIFajCCA1KgAwIBAgIUHnVLC8HrmS7TqxZdKXAlQdlDLqgwDQYJKoZIhvcNAQEL\nBQAwNjELMAkGA1UEBhMCVVMxEDAOBgNVBAoMB2N4IHRlc3QxFTATBgNVBAMMDGN4\nIHRlc3Qgcm9vdDAgFw0yNjEwMTEwNzA0MjhaGA8yMTI2MDkxNzA3MDQyOFowPjEL\nMAkGA1UEBhMCVVMxEDAOBgNVBAoMB2N4IHRlc3QxHTAbBgNVBAMMFGN4IHRlc3Qg\naW50ZXJtZWRpYXRlMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAt6nL\nYH/XqeH5sirb3lSFIt51dnZDMCsyI4KhM3L6IyBsBMMhNI2sqqTNfUsrWEaqAQSF\nkO6fNgQ9DaTbnF5rtX5zlASNBhwZu9Ti60HwOt7abgIupIN2aWLoLCbnZjv6J/bG\nY6nDZV6yNxrBYN0edit+podVw+8y+rObe0rnFWoDYC9JMB9zb6QKRs31phcSq7qT\nNNVBS8CnrbI6idcYqqrNc44E++X4MTRqahoMsTcpCThgQ+0XnMMiJpJbukdZDbOw\nzMp8tqjz5nMNploZ55gBXwxQZVEsYQqI98s7LutyeKyZ5sPbD2Z0qQ0buwvijxDl\nRydaekF7mmA3nGxI/IAMJktYKmWeUseFJ+Dk8x0tapgGGXnF+yKjRZOf2kHQ0j8t\ng6iiCy5+oe09doUZR1WrsvBMLAjx807hM2TjpM7un1U+qxXKpQsn6bcShIYMuIdb\nDI5v/CPT065PBt4YkSkF0FcBklMXF4vQRRfLfqZH19nWS46HHEsxUB7w4Z63MtwE\ncYM50Q39Vy9YiZeOibxQe57Fic48XEGiXyNjdQONLv5EziCkj4fAMh6HJojrfONr\nUy3kC1A2BiGcnFdidKBZrOrwA0NjJ85M8linGwlKpwD1kXsgw4Ext8FygbyWw1EC\nuDuMSjx+JwXvdQWeRW1VYX+jBFKJ++811QvCHN0CAwEAAaNmMGQwEgYDVR0TAQH/\nBAgwBgEB/wIBADAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFHoUfZF5EIi3GF//\n1hobF4jn2TV5MB8GA1UdIwQYMBaAFMvJrhT4XHO+Q3/CeY0O9iIt80//MA0GCSqG\nSIb3DQEBCwUAA4ICAQA4kkikxNW1pHGBJg+6OrnSY9xzKQO3a4Bbf4Ta+m9yBabd\n3XvUxqOsWqs3Pkrcn9saO4nErHJvjE69yhGmGrjifCYYGvmk037PRHcS4mcURV+N\nF9vzydpwRdv7ckhaXnAfWS3jUz1b2hLfPb9R0FoZ4B5btQc5VHk4PmnB3EmQrFXP\ngXmQcu8BFqOfbmIcdrNsRfZgDzml0t6/+pqN5ei3OLe8We6ScQKp0S8q3ITPkmv3\npjhPCyMHQTnAXCwrvCxDf092TrQ5YGVrWMbIiWbuTGxRejBNG81u8ol7uqPu1JH7\n2mcFJqnm3nMLV19Pay/77o1Xkm0tzXN5LwGCg3gQIFXgQ12ZUli4MZQiLVKfnmzf\nqLlCU2DSGNtUZcL2Muf30m7Rw6vsBiy/bo6uuvUXlsyEjs2ZzHhKoaba9SqXCGLt\nQwFOikCf030+ZC0cCL2w+JGgkjqYwiVFfzWmVGicvTx8ZT4R2/7K8FMU95upcMjF\nSV6gn8F9SKZHd8jfSHqKH3ruO1HsOABHXu62F/83ksTDYkV5wh+NK1TdD4K0RcNd\nX6QJ2RCHuZsY/1tNdjC5LBgRWBAEnhBSkJ0z8aywT0NlijwJrbChbMHHyv/1/wdy\nzdwmkci56kTmTJkQ9vSvW0u12SnMeZwWM7vgBinLOPgnZ0ea3Ut0+PfRYIP+Zw==\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nMIIFTzCCAzegAwIBAgIULsImk5z8UgUo4uTAvnwAoSkmE0cwDQYJKoZIhvcNAQEL\nBQAwNjELMAkGA1UEBhMCVVMxEDAOBgNVBAoMB2N4IHRlc3QxFTATBgNVBAMMDGN4\nIHRlc3Qgcm9vdDAgFw0yNjEwMTEwNzA0MjhaGA8yMTI2MDkxNzA3MDQyOFowNjEL\nMAkGA1UEBhMCVVMxEDAOBgNVBAoMB2N4IHRlc3QxFTATBgNVBAMMDGN4IHRlc3Qg\ncm9vdDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMZ3s6VltqmMWYu9\nZpLVD9oWWYiO8Ol0AS8GgGzmVhhZG6ZPIAaMgyCHyhBF4p6BbYESWhiFV6uJjC2T\n/fj4tU5DEdfIc5TGcbWOL3nhkNAzqMISXQZpphAzMQ9R6OKvx5AnOLWG6S1kEyJ9\neJokqL+YoIuJxwF75IqI2rrh7+ZGXpu0VnwsF0bxNh19CxYclaUDRNVvICydQ0AX\nKWbGXiwRHvVBr3nwfN9FFQKLPiY0V1v9kZBlL50ut0pb6Wqaf+n1fZBLwj8zBZ8V\nLf3BQdhQBhpGRGEdRdV+MvCnYwuhZ1gnhEUl2rBuyOT7mlsBVHPD/2CvrZJgEx2b\nVDsFMPd0vurba4HkjWBrf6gxzjfnzQhNE+s8qDNqsMvck0Wz0RswDfeoVqZaQCCf\nylhbnnUwH6wrdBh5Qbwik+nlWrJZaXvsqETyp4kVAPzcpaSHlpTny7cSAIE1E8RY\nSd9SgY7RZU8bIVmPWSZwN3Xkb8i7csOKtzWaq0tgAsY9wZx9hhL617E6puA/oxGl\n4kgUoiIh8nW8bTEj5vlp/TpfQGHOEUSHkogocYdd+TPVUMuLdIyKF7EWb5ZsacT5\nrizvXRYf37F+t7DXI1L3Dw17R+fpxoDtOmciwjCgSRX7VF+zGttEjqii6vgyKMUR\nkuhXKw2RF4zVoPRuQUU82+Cc2XqPAgMBAAGjUzBRMB0GA1UdDgQWBBTLya4U+Fxz\nvkN/wnmNDvYiLfNP/zAfBgNVHSMEGDAWgBTLya4U+FxzvkN/wnmNDvYiLfNP/zAP\nBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4ICAQCcYYi7quNtw/65Rec4\n3Y96J/V8xNkK1NcjowRGi0+Wqk0Huswvhosp1sFfwGMT76jfiNBSMHXYTyVhHsw3\nU0c95KbxJ/Z4h6foZZx5V1ktMwtteJPcol2oBzceOTDRwUo7bN1VQKCpseMaE0u+\n8EHp6MO6bBIcO+kMPNN4XmhzM0c5ZOpF23GUnRvIN5Wvzhz9S9unvDkcXG/8qaV6\n8FnUuVmaEYgVYt3hH/slNi/RN4jXwzEcNu6HvOyockGvjWrnWcXyfg8Iys+C65w8\n5Jh0JHQtpaZTisQPrg0jLst/qCXZgvG7LeNADWRCl3YMF3w0JcpIUi/C8bgGRNgX\nyoDN50BNjwiVg4587uHTTNNigWmoW4zn1TLGd0lXYQLfAYjkcA6DuqHA4pXY+eF9\nHEbABGZDSPMnY93pdXY58Xf0JR93OAjt3f9BycP0Pvt5TggWjbrw4/GVJ5d3vVo5\n+N7aTV0KRu81SCsH/XmzmNvuU4gS+Izk+4LO3fCogsSWdIDMDksFyr9PAekEOgf1\nKv9q8Py2XOQcgDwmIEpXwnCB/fk1vwZLkMuBnJ/TohLSDbvG8qcpDSD8LA3GXcke\nsOLrdzUKPZmVEQxc7ejoY/ftA5pXG4J0x0kLFTLUV7inVNBDkleYE+5EmEqTVPfa\nLPw1bxzwFOjjrQdg8OeHMmf+wg==\n-----END CERTIFICATE-----\n'
const long_chain_key = '-----BEGIN RSA PRIVATE KEY-----\n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\n-----END RSA PRIVATE KEY-----\n'
const long_chain_root = '-----BEGIN CERTIFICATE-----\nMIIFTzCCAzegAwIBAgIULsImk5z8UgUo4uTAvnwAoSkmE0cwDQYJKoZIhvcNAQEL\nBQAwNjELMAkGA1UEBhMCVVMxEDAOBgNVBAoMB2N4IHRlc3QxFTATBgNVBAMMDGN4\nIHRlc3Qgcm9vdDAgFw0yNjEwMTEwNzA0MjhaGA8yMTI2MDkxNzA3MDQyOFowNjEL\nMAkGA1UEBhMCVVMxEDAOBgNVBAoMB2N4IHRlc3QxFTATBgNVBAMMDGN4IHRlc3Qg\ncm9vdDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMZ3s6VltqmMWYu9\nZpLVD9oWWYiO8Ol0AS8GgGzmVhhZG6ZPIAaMgyCHyhBF4p6BbYESWhiFV6uJjC2T\n/fj4tU5DEdfIc5TGcbWOL3nhkNAzqMISXQZpphAzMQ9R6OKvx5AnOLWG6S1kEyJ9\neJokqL+YoIuJxwF75IqI2rrh7+ZGXpu0VnwsF0bxNh19CxYclaUDRNVvICydQ0AX\nKWbGXiwRHvVBr3nwfN9FFQKLPiY0V1v9kZBlL50ut0pb6Wqaf+n1fZBLwj8zBZ8V\nLf3BQdhQBhpGRGEdRdV+MvCnYwuhZ1gnhEUl2rBuyOT7mlsBVHPD/2CvrZJgEx2b\nVDsFMPd0vurba4HkjWBrf6gxzjfnzQhNE+s8qDNqsMvck0Wz0RswDfeoVqZaQCCf\nylhbnnUwH6wrdBh5Qbwik+nlWrJZaXvsqETyp4kVAPzcpaSHlpTny7cSAIE1E8RY\nSd9SgY7RZU8bIVmPWSZwN3Xkb8i7csOKtzWaq0tgAsY9wZx9hhL617E6puA/oxGl\n4kgUoiIh8nW8bTEj5vlp/TpfQGHOEUSHkogocYdd+TPVUMuLdIyKF7EWb5ZsacT5\nrizvXRYf37F+t7DXI1L3Dw17R+fpxoDtOmciwjCgSRX7VF+zGttEjqii6vgyKMUR\nkuhXKw2RF4zVoPRuQUU82+Cc2XqPAgMBAAGjUzBRMB0GA1UdDgQWBBTLya4U+Fxz\nvkN/wnmNDvYiLfNP/zAfBgNVHSMEGDAWgBTLya4U+FxzvkN/wnmNDvYiLfNP/zAP\nBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4ICAQCcYYi7quNtw/65Rec4\n3Y96J/V8xNkK1NcjowRGi0+Wqk0Huswvhosp1sFfwGMT76jfiNBSMHXYTyVhHsw3\nU0c95KbxJ/Z4h6foZZx5V1ktMwtteJPcol2oBzceOTDRwUo7bN1VQKCpseMaE0u+\n8EHp6MO6bBIcO+kMPNN4XmhzM0c5ZOpF23GUnRvIN5Wvzhz9S9unvDkcXG/8qaV6\n8FnUuVmaEYgVYt3hH/slNi/RN4jXwzEcNu6HvOyockGvjWrnWcXyfg8Iys+C65w8\n5Jh0JHQtpaZTisQPrg0jLst/qCXZgvG7LeNADWRCl3YMF3w0JcpIUi/C8bgGRNgX\nyoDN50BNjwiVg4587uHTTNNigWmoW4zn1TLGd0lXYQLfAYjkcA6DuqHA4pXY+eF9\nHEbABGZDSPMnY93pdXY58Xf0JR93OAjt3f9BycP0Pvt5TggWjbrw4/GVJ5d3vVo5\n+N7aTV0KRu81SCsH/XmzmNvuU4gS+Izk+4LO3fCogsSWdIDMDksFyr9PAekEOgf1\nKv9q8Py2XOQcgDwmIEpXwnCB/fk1vwZLkMuBnJ/TohLSDbvG8qcpDSD8LA3GXcke\nsOLrdzUKPZmVEQxc7ejoY/ftA5pXG4J0x0kLFTLUV7inVNBDkleYE+5EmEqTVPfa\nLPw1bxzwFOjjrQdg8OeHMmf+wg==\n-----END CERTIFICATE-----\n'

fn serve_one(mut l mbedtls.SSLListener) !string {
	mut conn := l.accept()!
	mut buf := []u8{len: 64}
	n := conn.read(mut buf)!
	conn.write_string('pong-long-chain')!
	conn.shutdown() or {}
	return buf[..n].bytestr()
}

fn round_trip(mut listener mbedtls.SSLListener, client_config mbedtls.SSLConnectConfig) ! {
	port := listener.addr()!.port()!
	server := spawn serve_one(mut listener)
	mut client := mbedtls.new_ssl_conn(client_config)!
	client.dial('localhost', port)!
	client.write_string('ping-long-chain')!
	mut rbuf := []u8{len: 64}
	rn := client.read(mut rbuf)!
	assert rbuf[..rn].bytestr() == 'pong-long-chain'
	client.shutdown() or {}
	got := server.wait() or { return error('server leg failed: ${err}') }
	assert got == 'ping-long-chain'
}

fn test_server_sends_a_chain_over_4kb() {
	spawn fn () {
		time.sleep(60 * time.second)
		eprintln('mbedtls long cert chain test: timeout reached, exiting.')
		exit(1)
	}()
	mut listener := mbedtls.new_ssl_listener('127.0.0.1:0', mbedtls.SSLConnectConfig{
		cert:                   long_chain_pem
		cert_key:               long_chain_key
		validate:               false
		in_memory_verification: true
	})!
	defer {
		listener.shutdown() or {}
	}
	round_trip(mut listener, mbedtls.SSLConnectConfig{
		verify:                 long_chain_root
		validate:               true
		in_memory_verification: true
	}) or { panic('a server chain of three RSA-4096 certificates failed the handshake: ${err}') }
}

fn test_client_sends_a_chain_over_4kb() {
	mut listener := mbedtls.new_ssl_listener('127.0.0.1:0', mbedtls.SSLConnectConfig{
		verify:                 long_chain_root
		cert:                   long_chain_pem
		cert_key:               long_chain_key
		validate:               true
		in_memory_verification: true
	})!
	defer {
		listener.shutdown() or {}
	}
	round_trip(mut listener, mbedtls.SSLConnectConfig{
		verify:                 long_chain_root
		cert:                   long_chain_pem
		cert_key:               long_chain_key
		validate:               true
		in_memory_verification: true
	}) or { panic('a client chain of three RSA-4096 certificates failed the handshake: ${err}') }
}
