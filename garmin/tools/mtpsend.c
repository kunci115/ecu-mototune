// mtpsend <local file> <remote name> <parent folder id>: libmtp's mtp-sendfile can't target a folder; this can.
#include <libmtp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: mtpsend <local> <remote name> <parent id>\n"); return 2; }
    LIBMTP_Init();
    LIBMTP_mtpdevice_t *dev = LIBMTP_Get_First_Device();
    if (!dev) { fprintf(stderr, "no MTP device\n"); return 1; }
    struct stat st; if (stat(argv[1], &st) != 0) { perror("stat"); return 1; }
    LIBMTP_file_t *f = LIBMTP_new_file_t();
    f->filesize = st.st_size; f->filename = strdup(argv[2]);
    f->filetype = LIBMTP_FILETYPE_UNKNOWN; f->parent_id = (uint32_t)strtoul(argv[3], NULL, 10);
    f->storage_id = dev->storage ? dev->storage->id : 0;
    int rc = LIBMTP_Send_File_From_File(dev, argv[1], f, NULL, NULL);
    if (rc != 0) { LIBMTP_Dump_Errorstack(dev); LIBMTP_Clear_Errorstack(dev); }
    else printf("sent %s -> parent %u as item %u\n", argv[1], f->parent_id, f->item_id);
    LIBMTP_destroy_file_t(f); LIBMTP_Release_Device(dev);
    return rc;
}
