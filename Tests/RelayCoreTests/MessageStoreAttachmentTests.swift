import Testing

@testable import RelayCore

@Test
func messageAttachmentsExposeDownloadRowID() throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO attachment
            (ROWID, filename, transfer_name, mime_type, uti, total_bytes, is_sticker)
        VALUES
            (700, '/missing/photo.jpg', 'photo.jpg', 'image/jpeg', 'public.jpeg', 123, 0);
        INSERT INTO message_attachment_join (message_id, attachment_id)
        VALUES (100, 700);
        """)

    let messages = try fixture.makeStore().messages(chatID: 1, includeAttachments: true)
    let attachment = try #require(messages.first?.attachments.first)

    #expect(attachment.id == 700)
    #expect(attachment.transferName == "photo.jpg")
    #expect(attachment.mimeType == "image/jpeg")
    #expect(attachment.missing)
}
