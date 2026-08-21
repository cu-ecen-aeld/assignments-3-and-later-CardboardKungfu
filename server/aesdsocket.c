#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <sys/socket.h>
#include <unistd.h>

#define PORT 9000
#define DATA_FILE "/var/tmp/aesdsocketdata"
#define BUFFER_SIZE 1024

static volatile sig_atomic_t shutdown_requested;

static void signal_handler(int signal_number)
{
	(void)signal_number;
	shutdown_requested = 1;
}

static int write_all(int fd, const char *buffer, size_t length)
{
	size_t written = 0;

	while (written < length) {
		ssize_t result = write(fd, buffer + written, length - written);
		if (result < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (result == 0)
			return -1;
		written += (size_t)result;
	}

	return 0;
}

static int send_file(int client_fd)
{
	char buffer[BUFFER_SIZE];
	int file_fd = open(DATA_FILE, O_RDONLY);
	if (file_fd < 0)
		return -1;

	for (;;) {
		ssize_t bytes_read = read(file_fd, buffer, sizeof(buffer));
		if (bytes_read == 0)
			break;
		if (bytes_read < 0) {
			if (errno == EINTR)
				continue;
			close(file_fd);
			return -1;
		}
		if (write_all(client_fd, buffer, (size_t)bytes_read) < 0) {
			close(file_fd);
			return -1;
		}
	}

	close(file_fd);
	return 0;
}

static int append_packet(const char *packet, size_t length)
{
	int file_fd = open(DATA_FILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (file_fd < 0)
		return -1;

	int result = write_all(file_fd, packet, length);
	if (close(file_fd) < 0)
		result = -1;
	return result;
}

static int daemonize_process(void)
{
	pid_t child_pid = fork();
	if (child_pid < 0)
		return -1;
	if (child_pid > 0)
		return 1;

	if (setsid() < 0)
		return -1;
	if (chdir("/") < 0)
		return -1;

	int null_fd = open("/dev/null", O_RDWR);
	if (null_fd < 0)
		return -1;
	if (dup2(null_fd, STDIN_FILENO) < 0 ||
	    dup2(null_fd, STDOUT_FILENO) < 0 ||
	    dup2(null_fd, STDERR_FILENO) < 0) {
		close(null_fd);
		return -1;
	}
	if (null_fd > STDERR_FILENO)
		close(null_fd);

	return 0;
}

static int process_client(int client_fd)
{
	char receive_buffer[BUFFER_SIZE];
	char *packet = NULL;
	size_t packet_length = 0;
	size_t packet_capacity = 0;
	bool discard_packet = false;

	for (;;) {
		ssize_t bytes_received = recv(client_fd, receive_buffer,
						      sizeof(receive_buffer), 0);
		if (bytes_received == 0)
			break;
		if (bytes_received < 0) {
			if (errno == EINTR && shutdown_requested)
				break;
			if (errno == EINTR)
				continue;
			syslog(LOG_ERR, "recv failed: %s", strerror(errno));
			break;
		}

		for (ssize_t index = 0; index < bytes_received; index++) {
			char current = receive_buffer[index];

			if (!discard_packet) {
				if (packet_length == packet_capacity) {
					size_t new_capacity = packet_capacity == 0 ? BUFFER_SIZE :
							packet_capacity * 2;
					char *new_packet = realloc(packet, new_capacity);
					if (new_packet == NULL) {
						syslog(LOG_ERR, "Unable to allocate packet buffer");
						discard_packet = true;
						packet_length = 0;
					} else {
						packet = new_packet;
						packet_capacity = new_capacity;
					}
				}
				if (!discard_packet)
					packet[packet_length++] = current;
			}

			if (current == '\n') {
				if (!discard_packet) {
					if (append_packet(packet, packet_length) < 0) {
						syslog(LOG_ERR, "Unable to append packet: %s",
						       strerror(errno));
						free(packet);
						return -1;
					}
					if (send_file(client_fd) < 0) {
						free(packet);
						return -1;
					}
				}
				packet_length = 0;
				discard_packet = false;
			}
		}
	}

	free(packet);
	return 0;
}

int main(int argc, char *argv[])
{
	struct sigaction signal_action = {0};
	struct sockaddr_in server_address = {0};
	int server_fd = -1;
	bool daemon_mode = false;
	int option;

	while ((option = getopt(argc, argv, "d")) != -1) {
		if (option == 'd')
			daemon_mode = true;
		else
			return -1;
	}

	openlog("aesdsocket", LOG_PID, LOG_USER);
	signal_action.sa_handler = signal_handler;
	sigemptyset(&signal_action.sa_mask);
	if (sigaction(SIGINT, &signal_action, NULL) < 0 ||
	    sigaction(SIGTERM, &signal_action, NULL) < 0) {
		syslog(LOG_ERR, "Unable to install signal handler: %s", strerror(errno));
		closelog();
		return -1;
	}
	signal(SIGPIPE, SIG_IGN);

	unlink(DATA_FILE);
	server_fd = socket(AF_INET, SOCK_STREAM, 0);
	if (server_fd < 0)
		goto error;

	int reuse = 1;
	if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
		       sizeof(reuse)) < 0)
		goto error;

	server_address.sin_family = AF_INET;
	server_address.sin_addr.s_addr = htonl(INADDR_ANY);
	server_address.sin_port = htons(PORT);
	if (bind(server_fd, (struct sockaddr *)&server_address,
		 sizeof(server_address)) < 0 || listen(server_fd, 10) < 0)
		goto error;

	if (daemon_mode) {
		int daemon_result = daemonize_process();
		if (daemon_result < 0)
			goto error;
		if (daemon_result > 0) {
			close(server_fd);
			closelog();
			return 0;
		}
	}

	while (!shutdown_requested) {
		struct sockaddr_in client_address = {0};
		socklen_t client_length = sizeof(client_address);
		int client_fd = accept(server_fd, (struct sockaddr *)&client_address,
				       &client_length);
		if (client_fd < 0) {
			if (errno == EINTR && shutdown_requested)
				break;
			if (errno == EINTR)
				continue;
			syslog(LOG_ERR, "accept failed: %s", strerror(errno));
			continue;
		}

		char client_ip[INET_ADDRSTRLEN] = "unknown";
		(void)inet_ntop(AF_INET, &client_address.sin_addr, client_ip,
				 sizeof(client_ip));
		syslog(LOG_INFO, "Accepted connection from %s", client_ip);
		process_client(client_fd);
		close(client_fd);
		syslog(LOG_INFO, "Closed connection from %s", client_ip);
	}

	syslog(LOG_INFO, "Caught signal, exiting");
	close(server_fd);
	unlink(DATA_FILE);
	closelog();
	return 0;

error:
	if (server_fd >= 0)
		close(server_fd);
	unlink(DATA_FILE);
	closelog();
	return -1;
}
