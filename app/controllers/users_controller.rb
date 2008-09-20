class UsersController < ApplicationController
  before_filter :check_user_status, :only => [:edit, :update]
  before_filter :is_owner, :only => [:edit, :update, :destroy]
  before_filter :check_account_creation_status, :only => [:new, :create]
  
  # Ensure that the current user is authorized to make changes
  def is_owner
    @user = User.find_by_login(params[:id])
    @user == current_user || access_denied
  end
  
  def check_account_creation_status
    unless ArchiveConfig.ACCOUNT_CREATION_ENABLED
      flash[:error] = "Account creation is suspended at the moment. Please check back with us later.".t
      redirect_to login_path 
    end
  end
  
  def index
    @users = User.alphabetical.paginate(:page => params[:page])
    filter_out = [TagCategory.find_by_name("Warning")] + [TagCategory.find_by_name("Rating")] + [TagCategory.default]
    @categories = TagCategory.official - filter_out
  end 

  # GET /users/1
  # GET /users/1.xml
  def show
    @user = User.find_by_login(params[:id])
    if params[:open_id_complete] then
      begin
        open_id_authentication(params[:open_id_complete])
      rescue
        render :action => "edit"
      end
    end
    @works = @user.works.visible(:limit => ArchiveConfig.NUMBER_OF_ITEMS_VISIBLE_IN_DASHBOARD, :order => 'works.updated_at DESC')
    @series = @user.series.find(:all, :limit => ArchiveConfig.NUMBER_OF_ITEMS_VISIBLE_IN_DASHBOARD, :order => 'series.updated_at DESC')
    @bookmarks = @user.bookmarks.visible(:limit => ArchiveConfig.NUMBER_OF_ITEMS_VISIBLE_IN_DASHBOARD, :order => 'bookmarks.updated_at DESC')  
  end
  
  # GET /users/new
  # GET /users/new.xml
  def new
    @user = User.new
		@hide_dashboard = true
  end
  
  # GET /users/1/edit
  def edit
    @user = User.find_by_login(params[:id])
  end
  
  # POST /users
  # POST /users.xml
  def create
	  @hide_dashboard = true
    if params["cancel-create-account"] == "Cancel"
      redirect_to '/'
    else
      @user = User.new(params[:user]) 
      begin @user.save
        flash[:notice] = 'during testing you can activate via <a href=' + activate_path(@user.activation_code) + '>your activation url</a>.' if ENV['RAILS_ENV'] == 'development'
  
        render :partial => "confirmation", :layout => "application"
      rescue
        flash[:error] = "Duplicate OpenID URL.".t
        render :action => "new"
      end
    end
  end
  
  def activate
    if params[:id].blank?
      flash[:error] = "Your activation key is missing.".t
      redirect_to ''
    else
      @user = User.find_by_activation_code(params[:id])
      if @user
        @user.activate
        self.current_user = @user
        flash[:notice] = "Signup complete! This is your public profile.".t
        redirect_to(@user)
      else
        flash[:error] = "Your activation key is invalid. Perhaps it has expired.".t
        redirect_to '' 
      end
    end
  end
  
  def after_reset
    @user = User.find_by_login(params[:id])  
  end
  
  # PUT /users/1
  # PUT /users/1.xml
  def update
    @user = User.find_by_login(params[:id])
    begin 
      if @user.profile
        @user.profile.update_attributes! params[:profile_attributes]
      else
        @user.profile = Profile.new(params[:profile_attributes])
        @user.profile.save!
      end
      @user.recently_reset = nil if params[:change_password]
      if !params[:user][:password].blank? && !@user.authenticated?(params[:user][:password], @user.salt) && !@user.authenticated?(params[:check][:password_check], @user.salt)
        flash[:error] = "Your old password was incorrect".t
        unsuccessful_update
      end
      if params[:user][:identity_url] != @user.identity_url && !params[:user][:identity_url].blank?
        open_id_authentication(params[:user][:identity_url])
      else
        successful_update
      end      
   rescue
      render :action => "edit"
   end
  end
  
  # DELETE /users/1
  # DELETE /users/1.xml
  def destroy
    @hide_dashboard = true
    @user = User.find_by_login(params[:id])
    if @user.works.blank?
      @user.destroy
      flash[:notice] = 'You have successfully deleted your account.'.t
      redirect_to(delete_confirmation_path)
    elsif params[:coauthor].blank? && params[:sole_author].blank?
      @sole_authored_works = @user.sole_authored_works
      @coauthored_works = @user.coauthored_works
      render :partial => 'delete_preview', :layout => 'application'
    elsif params[:coauthor] || params[:sole_author]
      @sole_authored_works = @user.sole_authored_works
      @coauthored_works = @user.coauthored_works
      # Orphans co-authored works, keeps the user's pseud on the orphan account
      if params[:coauthor] == 'keep_pseud'
        pseuds = @user.pseuds
        works = @coauthored_works
        use_default = params[:use_default] == "true"
        Creatorship.orphan(pseuds, works, use_default)
      # Orphans co-authored works, changes pseud to the default orphan pseud
      elsif params[:coauthor] == 'orphan_pseud'
        pseuds = @user.pseuds
        works = @coauthored_works
        Creatorship.orphan(pseuds, works)
      # Removes user as an author from co-authored works
      elsif params[:coauthor] == 'remove'
        @coauthored_works.each do |w|
          pseuds_with_author_removed = w.pseuds - @user.pseuds
          w.pseuds = pseuds_with_author_removed
          w.save
          w.chapters.each do |c| 
            c.pseuds = c.pseuds - @user.pseuds
            if c.pseuds.empty?
              c.pseuds = w.pseuds
            end
            c.save
          end
        end
      end  
      # Orphans works where user is sole author, keeps their pseud on the orphan account
      if params[:sole_author] == 'keep_pseud'
        pseuds = @user.pseuds
        works = @sole_authored_works
        use_default = params[:use_default] == "true"        
        Creatorship.orphan(pseuds, works, use_default)
      # Orphans works where user is sole author, uses the default orphan pseud
      elsif params[:sole_author] == 'orphan_pseud'
        pseuds = @user.pseuds
        works = @sole_authored_works
        Creatorship.orphan(pseuds, works)        
      # Deletes works where user is sole author
      elsif params[:sole_author] == 'delete'
        @sole_authored_works.each do |s|
          s.destroy
        end
      end
      @works = @user.works.find(:all)
      if @works.blank?
        @user.destroy
        flash[:notice] = 'You have successfully deleted your account.'.t
        redirect_to(delete_confirmation_path)
      else
        flash[:error] = "Sorry, something went wrong! Please try again.".t
        redirect_to(@user)      
      end
    end
  end
  
  def delete_confirmation
  end
  
 
  protected
    def successful_update
      @user.update_attributes!(params[:user]) 
      flash[:notice] = 'Your profile has been successfully updated.'.t
      redirect_to(user_profile_path(@user)) 
    end
    
    def unsuccessful_update
       raise
    end
      
    def open_id_authentication(openid_url)
      authenticate_with_open_id(openid_url) do |result, identity_url, registration|
        if result.successful?
          @user.update_attribute(:identity_url, identity_url) 
          flash[:notice] = 'Your profile has been successfully updated.'.t
          redirect_to(user_profile_path(@user)) 
        else
          flash[:error] = result.message
          raise
        end 
      end
    end
     
end
