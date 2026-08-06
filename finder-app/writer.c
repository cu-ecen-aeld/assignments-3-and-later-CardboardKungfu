#include <stdio.h>
#include <syslog.h>
#include <errno.h>
#include <string.h>

int main(int argc, char *argv[]) {
    openlog(NULL, 0, LOG_USER);

    if(argc < 3) {
        syslog(LOG_ERR, "Error: Two arguments required.\nUsage: %s <writefile> <writestr>", argv[0]);
        return 1;
    }

    const char *writefile = argv[1];
    const char *writestr = argv[2];

    FILE *file = fopen(writefile, "w+");

    if(file == NULL) {
        perror("Failed to open file");
        return 1;
    }

    size_t length = strlen(writestr);
    syslog(LOG_DEBUG, "Writing %s to %s", writestr, writefile);
    size_t written = fwrite(writestr, sizeof(char), length, file);

    if(written == length) {
        syslog(LOG_DEBUG, "File successfully written.");
    } else {
        syslog(LOG_ERR, "Error: Only wrote %zu of %zu bytes.\n", written, length);
        return 1;
    }

    fclose(file);
    return 0;
}