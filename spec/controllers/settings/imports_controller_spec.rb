# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::ImportsController do
  render_views

  let(:user) { Fabricate(:user) }

  before do
    sign_in user, scope: :user
  end

  describe 'GET #index' do
    let!(:import)       { Fabricate(:bulk_import, account: user.account) }
    let!(:other_import) { Fabricate(:bulk_import) }

    before do
      get :index
    end

    it 'assigns the expected imports' do
      expect(assigns(:recent_imports)).to eq [import]
    end

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'returns private cache control headers' do
      expect(response.headers['Cache-Control']).to include('private, no-store')
    end
  end

  describe 'GET #show' do
    before do
      get :show, params: { id: bulk_import.id }
    end

    context 'with someone else\'s import' do
      let(:bulk_import) { Fabricate(:bulk_import, state: :unconfirmed) }

      it 'returns http not found' do
        expect(response).to have_http_status(404)
      end
    end

    context 'with an already-confirmed import' do
      let(:bulk_import) { Fabricate(:bulk_import, account: user.account, state: :in_progress) }

      it 'returns http not found' do
        expect(response).to have_http_status(404)
      end
    end

    context 'with an unconfirmed import' do
      let(:bulk_import) { Fabricate(:bulk_import, account: user.account, state: :unconfirmed) }

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end
    end
  end

  describe 'POST #confirm' do
    subject { post :confirm, params: { id: bulk_import.id } }

    before do
      allow(BulkImportWorker).to receive(:perform_async)
    end

    context 'with someone else\'s import' do
      let(:bulk_import) { Fabricate(:bulk_import, state: :unconfirmed) }

      it 'does not change the import\'s state' do
        expect { subject }.to_not(change { bulk_import.reload.state })
      end

      it 'does not fire the import worker' do
        subject
        expect(BulkImportWorker).to_not have_received(:perform_async)
      end

      it 'returns http not found' do
        subject
        expect(response).to have_http_status(404)
      end
    end

    context 'with an already-confirmed import' do
      let(:bulk_import) { Fabricate(:bulk_import, account: user.account, state: :in_progress) }

      it 'does not change the import\'s state' do
        expect { subject }.to_not(change { bulk_import.reload.state })
      end

      it 'does not fire the import worker' do
        subject
        expect(BulkImportWorker).to_not have_received(:perform_async)
      end

      it 'returns http not found' do
        subject
        expect(response).to have_http_status(404)
      end
    end

    context 'with an unconfirmed import' do
      let(:bulk_import) { Fabricate(:bulk_import, account: user.account, state: :unconfirmed) }

      it 'changes the import\'s state to scheduled' do
        expect { subject }.to change { bulk_import.reload.state.to_sym }.from(:unconfirmed).to(:scheduled)
      end

      it 'fires the import worker on the expected import' do
        subject
        expect(BulkImportWorker).to have_received(:perform_async).with(bulk_import.id)
      end

      it 'redirects to imports path' do
        subject
        expect(response).to redirect_to(settings_imports_path)
      end
    end
  end

  describe 'DELETE #destroy' do
    subject { delete :destroy, params: { id: bulk_import.id } }

    context 'with someone else\'s import' do
      let(:bulk_import) { Fabricate(:bulk_import, state: :unconfirmed) }

      it 'does not delete the import' do
        expect { subject }.to_not(change { BulkImport.exists?(bulk_import.id) })
      end

      it 'returns http not found' do
        subject
        expect(response).to have_http_status(404)
      end
    end

    context 'with an already-confirmed import' do
      let(:bulk_import) { Fabricate(:bulk_import, account: user.account, state: :in_progress) }

      it 'does not delete the import' do
        expect { subject }.to_not(change { BulkImport.exists?(bulk_import.id) })
      end

      it 'returns http not found' do
        subject
        expect(response).to have_http_status(404)
      end
    end

    context 'with an unconfirmed import' do
      let(:bulk_import) { Fabricate(:bulk_import, account: user.account, state: :unconfirmed) }

      it 'deletes the import' do
        expect { subject }.to change { BulkImport.exists?(bulk_import.id) }.from(true).to(false)
      end

      it 'redirects to imports path' do
        subject
        expect(response).to redirect_to(settings_imports_path)
      end
    end
  end

  describe 'GET #failures' do
    subject { get :failures, params: { id: bulk_import.id }, format: :csv }

    shared_examples 'export failed rows' do |expected_contents|
      let(:bulk_import) { Fabricate(:bulk_import, account: user.account, type: import_type, state: :finished) }

      before do
        bulk_import.update(total_items: bulk_import.rows.count, processed_items: bulk_import.rows.count, imported_items: 0)
      end

      it 'returns http success' do
        subject
        expect(response).to have_http_status(200)
      end

      it 'returns expected contents' do
        subject
        expect(response.body).to eq expected_contents
      end
    end

    context 'with follows' do
      let(:import_type) { 'following' }

      let!(:rows) do
        [
          { 'acct' => 'foo@bar' },
          { 'acct' => 'user@bar', 'show_reblogs' => false, 'notify' => true, 'languages' => %w(fr de) },
        ].map { |data| Fabricate(:bulk_import_row, bulk_import: bulk_import, data: data) }
      end

      include_examples 'export failed rows', "Account address,Show boosts,Notify on new posts,Languages\nfoo@bar,true,false,\nuser@bar,false,true,\"fr, de\"\n"
    end

    context 'with blocks' do
      let(:import_type) { 'blocking' }

      let!(:rows) do
        [
          { 'acct' => 'foo@bar' },
          { 'acct' => 'user@bar' },
        ].map { |data| Fabricate(:bulk_import_row, bulk_import: bulk_import, data: data) }
      end

      include_examples 'export failed rows', "foo@bar\nuser@bar\n"
    end

    context 'with mutes' do
      let(:import_type) { 'muting' }

      let!(:rows) do
        [
          { 'acct' => 'foo@bar' },
          { 'acct' => 'user@bar', 'hide_notifications' => false },
        ].map { |data| Fabricate(:bulk_import_row, bulk_import: bulk_import, data: data) }
      end

      include_examples 'export failed rows', "Account address,Hide notifications\nfoo@bar,true\nuser@bar,false\n"
    end

    context 'with domain blocks' do
      let(:import_type) { 'domain_blocking' }

      let!(:rows) do
        [
          { 'domain' => 'bad.domain' },
          { 'domain' => 'evil.domain' },
        ].map { |data| Fabricate(:bulk_import_row, bulk_import: bulk_import, data: data) }
      end

      include_examples 'export failed rows', "bad.domain\nevil.domain\n"
    end

    context 'with bookmarks' do
      let(:import_type) { 'bookmarks' }

      let!(:rows) do
        [
          { 'uri' => 'https://foo.com/1' },
          { 'uri' => 'https://foo.com/2' },
        ].map { |data| Fabricate(:bulk_import_row, bulk_import: bulk_import, data: data) }
      end

      include_examples 'export failed rows', "https://foo.com/1\nhttps://foo.com/2\n"
    end

    context 'with lists' do
      let(:import_type) { 'lists' }

      let!(:rows) do
        [
          { 'list_name' => 'Amigos', 'acct' => 'user@example.com' },
          { 'list_name' => 'Frenemies', 'acct' => 'user@org.org' },
        ].map { |data| Fabricate(:bulk_import_row, bulk_import: bulk_import, data: data) }
      end

      include_examples 'export failed rows', "Amigos,user@example.com\nFrenemies,user@org.org\n"
    end
  end

  describe 'POST #create' do
    subject do
      post :create, params: {
        form_import: {
          type: import_type,
          mode: import_mode,
          data: fixture_file_upload(import_file),
        },
      }
    end

    shared_examples 'successful import' do |type, file, mode|
      let(:import_type) { type }
      let(:import_file) { file }
      let(:import_mode) { mode }

      it 'creates an unconfirmed bulk_import with expected type' do
        expect { subject }.to change { user.account.bulk_imports.pluck(:state, :type) }.from([]).to([['unconfirmed', import_type]])
      end

      it 'redirects to confirmation page for the import' do
        subject
        expect(response).to redirect_to(settings_import_path(user.account.bulk_imports.first))
      end
    end

    shared_examples 'unsuccessful import' do |type, file, mode|
      let(:import_type) { type }
      let(:import_file) { file }
      let(:import_mode) { mode }

      it 'does not creates an unconfirmed bulk_import' do
        expect { subject }.to_not(change { user.account.bulk_imports.count })
      end

      it 'sets error to the import' do
        subject
        expect(assigns(:import).errors).to_not be_empty
      end
    end

    it_behaves_like 'successful import', 'following', 'imports.txt', 'merge'
    it_behaves_like 'successful import', 'following', 'imports.txt', 'overwrite'
    it_behaves_like 'successful import', 'blocking', 'imports.txt', 'merge'
    it_behaves_like 'successful import', 'blocking', 'imports.txt', 'overwrite'
    it_behaves_like 'successful import', 'muting', 'imports.txt', 'merge'
    it_behaves_like 'successful import', 'muting', 'imports.txt', 'overwrite'
    it_behaves_like 'successful import', 'domain_blocking', 'domain_blocks.csv', 'merge'
    it_behaves_like 'successful import', 'domain_blocking', 'domain_blocks.csv', 'overwrite'
    it_behaves_like 'successful import', 'bookmarks', 'bookmark-imports.txt', 'merge'
    it_behaves_like 'successful import', 'bookmarks', 'bookmark-imports.txt', 'overwrite'

    it_behaves_like 'unsuccessful import', 'following', 'domain_blocks.csv', 'merge'
    it_behaves_like 'unsuccessful import', 'following', 'domain_blocks.csv', 'overwrite'
    it_behaves_like 'unsuccessful import', 'blocking', 'domain_blocks.csv', 'merge'
    it_behaves_like 'unsuccessful import', 'blocking', 'domain_blocks.csv', 'overwrite'
    it_behaves_like 'unsuccessful import', 'muting', 'domain_blocks.csv', 'merge'
    it_behaves_like 'unsuccessful import', 'muting', 'domain_blocks.csv', 'overwrite'

    it_behaves_like 'unsuccessful import', 'following', 'empty.csv', 'merge'
    it_behaves_like 'unsuccessful import', 'following', 'empty.csv', 'overwrite'
  end
end
