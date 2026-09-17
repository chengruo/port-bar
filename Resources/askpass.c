#include <stdio.h>
#include <stdlib.h>

int main(void) {
    const char *password = getenv("PORTBAR_SSH_PASSWORD");
    if (password != NULL) {
        fputs(password, stdout);
        fputc('\n', stdout);
        fflush(stdout);
        return 0;
    }
    return 1;
}
